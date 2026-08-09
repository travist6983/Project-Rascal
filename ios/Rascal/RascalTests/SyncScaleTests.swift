import Foundation
import SwiftData
import Testing

@testable import Rascal

/// A full pull against an archive the size of the real one.
///
/// 736 is not an arbitrary number: it is how many entries are in the dev archive this engine will
/// meet the first time it runs for real. A cold start against it is the single largest thing the
/// pull ever does, and it happens on the screen a parent is looking at.
@MainActor
@Suite("Sync at scale")
struct SyncScaleTests {

    /// The dev archive's size, from `docs/roadmap-status.md`.
    static let archiveSize = 736

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// An archive of `count` entries, each with one photo, spread over several years.
    ///
    /// Every row shares nearly the same `updated_at`, which is what a bulk-imported archive
    /// actually looks like — and it is the worst case for the overlap window, because the whole
    /// archive falls inside the lag band and comes back a second time.
    private func archive(child: UUID, count: Int, updatedAt: Date) -> Data {
        var entries: [String] = []
        var media: [String] = []
        for index in 0..<count {
            let id = UUID()
            // One file, named once. The entry inlines its summary and the top-level array
            // carries the same row — which is exactly what the server sends, and what makes
            // both apply paths meet on one id rather than producing two rows per photo.
            let mediaId = UUID()
            let occurred = Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 86_400)
            entries.append(entryJSON(
                id: id, childId: child, occurredAt: occurred, type: "photo",
                body: "entry \(index)", ageMonths: 20 + index / 30,
                media: [mediaJSON(id: mediaId)], updatedAt: updatedAt
            ))
            media.append(syncMediaJSON(id: mediaId, entryId: id, updatedAt: updatedAt))
        }
        return syncJSON(entries: entries, media: media, cursor: laggedCursor(newest: updatedAt))
    }

    @Test("a cold start against 736 entries lands whole, and inside a sane budget")
    func fullPullAtArchiveScale() async throws {
        let context = try makeContext()
        let child = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let body = archive(child: child, count: Self.archiveSize, updatedAt: updatedAt)

        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let state = InMemorySyncStateStore(pullEnabled: true)
        let engine = SyncEngine(
            childId: child,
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            context: context,
            state: state
        )

        let started = ContinuousClock.now
        let plan = try #require(await engine.pull().plan)
        let elapsed = ContinuousClock.now - started

        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == Self.archiveSize)
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == Self.archiveSize)
        #expect(plan.count(.entry, .insert) == Self.archiveSize)
        #expect(state.cursor(for: child) == laggedCursor(newest: updatedAt))

        // Generous on purpose: this is a simulator under a test runner, and the number that
        // matters is the order of magnitude. Seconds is fine; a minute is a defect.
        #expect(elapsed < .seconds(30), "a cold start took \(elapsed)")
    }

    @Test("the whole archive arriving twice is applied once")
    func wholeArchiveReDeliveredIsIdempotent() async throws {
        let context = try makeContext()
        let child = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let body = archive(child: child, count: Self.archiveSize, updatedAt: updatedAt)

        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let engine = SyncEngine(
            childId: child,
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            context: context,
            state: InMemorySyncStateStore(pullEnabled: true)
        )

        let plan = try #require(await engine.pull().plan)

        // Every row shares an `updated_at`, so the entire archive falls inside the lag band and
        // round two re-reads all of it. That is the window working, and the reason every apply
        // path is a pure assignment rather than an accumulation.
        #expect(plan.rounds == 2)
        #expect(plan.fetched == Self.archiveSize * 4, "736 entries and 736 media, twice")
        #expect(plan.reDeliveredAcrossRounds == Self.archiveSize * 2)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == Self.archiveSize,
                "re-delivery must not produce a second copy of anything")
        #expect(plan.count(.entry, .insert) == Self.archiveSize,
                "and the report still says what actually happened")
    }

    /// The main actor is where the apply runs, because that is where the `ModelContext` the app's
    /// views read from lives. This asserts the apply **yields** rather than holding the actor for
    /// the whole batch — cooperative, not off-thread, and stated that way deliberately.
    @Test("a full pull hands the main actor back repeatedly instead of holding it")
    func applyYieldsToTheMainActor() async throws {
        let context = try makeContext()
        let child = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let body = archive(child: child, count: Self.archiveSize, updatedAt: updatedAt)

        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let engine = SyncEngine(
            childId: child,
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            context: context,
            state: InMemorySyncStateStore(pullEnabled: true)
        )

        // A main-actor task that only counts how often it gets a turn. If the apply monopolised
        // the actor this would run once at the start and once at the end.
        let ticker = Task { @MainActor in
            var ticks = 0
            while !Task.isCancelled {
                ticks += 1
                await Task.yield()
            }
            return ticks
        }

        await engine.pull()
        ticker.cancel()
        let ticks = await ticker.value

        #expect(ticks > 10, "the run loop got \(ticks) turns during the apply")
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == Self.archiveSize)
    }
}
