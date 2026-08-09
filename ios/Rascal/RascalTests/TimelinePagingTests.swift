import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Paging, and the states around its edges.
///
/// The client pages by asking for everything older than the oldest row on screen, and reads the
/// server's `next_cursor` only as "is there more". These assert that bargain: seed from the
/// cache, overlap rather than skip, stop when the server says there is no next page, and never
/// loop on a request that returns nothing new.
@MainActor
@Suite("Timeline paging")
struct TimelinePagingTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    /// Two pages then a stop, driven by how many times `/entries` has been asked.
    private func pagedPerformer(child: UUID) -> StubPerformer {
        let performer = StubPerformer()
        let first = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: Date(timeIntervalSince1970: 1_700_000_000))],
            cursor: "cursor-one"
        )
        let second = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: Date(timeIntervalSince1970: 1_600_000_000))],
            cursor: nil
        )
        performer.on("/entries") { hit in (hit == 1 ? first : second, 200) }
        return performer
    }

    private func befores(_ performer: StubPerformer) -> [String?] {
        performer.requests
            .filter { $0.url?.path().contains("/entries") ?? false }
            .map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "before" }?.value
            }
    }

    @Test("the first page asks for no window at all")
    func firstPageTakesNoWindow() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()

        #expect(befores(performer) == [nil])
        #expect(model.hasLoaded)
        #expect(model.reachedEnd == false, "the server offered another page")
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)
    }

    @Test("the next page asks for everything older than the oldest row on screen")
    func nextPageSeedsFromTheCache() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()

        let asked = befores(performer)
        #expect(asked.count == 2)
        #expect(asked[0] == nil)
        // One second past the oldest cached row: `before` is exclusive and two entries can
        // share an instant, so a boundary drawn exactly at the oldest row can skip its twin.
        let window = try #require(asked[1].flatMap(ISO8601Formatters.parse))
        #expect(abs(window.timeIntervalSince1970 - 1_700_000_001) < 1)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 2)
    }

    @Test("a page the server marks as the last one stops paging for good")
    func lastPageStops() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()
        #expect(model.reachedEnd)

        // The footer reappears every time the list settles; it must not turn into a loop.
        await model.loadMoreIfNeeded()
        await model.loadMoreIfNeeded()

        #expect(performer.count(for: "/entries") == 2)
    }

    @Test("an empty first page is a finished, empty archive rather than a spinner")
    func emptyFirstPage() async throws {
        let context = try makeContext()
        let performer = StubPerformer()
        let empty = pageJSON([], cursor: nil)
        performer.on("/entries") { _ in (empty, 200) }

        let model = TimelineModel(childId: UUID(), api: client(performer), context: context)
        await model.start()

        #expect(model.hasLoaded, "nothing fetched yet and nothing in the archive must not look the same")
        #expect(model.reachedEnd)
        #expect(model.notice == nil)
        await model.loadMoreIfNeeded()
        #expect(performer.count(for: "/entries") == 1)
    }

    @Test("changing the filter restarts paging rather than carrying a window across lists")
    func filterResetsPaging() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.apply(.photo)

        // A window belongs to one list. Carrying it into another would page the photo filter
        // from a position established by the unfiltered one.
        #expect(befores(performer) == [nil, nil])
        let types = performer.requests.compactMap { request -> String? in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "type" }?.value
        }
        #expect(types == ["photo"])
    }

    @Test("a warm cache pages on from its own floor, not from where page one ended")
    func warmCachePagesOnward() async throws {
        // The defect a device found. Reopen the app with many pages already cached and the
        // page-one position asks for rows the cache already holds: no new card appears, nothing
        // triggers again, and the timeline stops at the bottom of the cache with years of
        // archive still unfetched. Seeding from the cache's own floor is the fix.
        let context = try makeContext()
        let child = UUID()
        let floor = Date(timeIntervalSince1970: 1_650_000_000)

        EntryCache.upsert(
            try (0..<10).map { index in
                try decodeEntry(entryJSON(
                    id: UUID(), childId: child,
                    occurredAt: floor.addingTimeInterval(Double(index) * 86_400)
                ))
            },
            into: context
        )

        let performer = pagedPerformer(child: child)
        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()

        let asked = befores(performer)
        let window = try #require(asked.last.flatMap { $0 }.flatMap(ISO8601Formatters.parse))
        #expect(
            abs(window.timeIntervalSince(floor) - 1) < 1,
            "the request must be older than everything on screen, not older than page one"
        )
    }

    @Test("a page that returns only rows already held is the end, not a loop")
    func doesNotLoopOnAnUnmovedFloor() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        // Always the same row, and always another cursor: a server that never advances.
        let stuck = pageJSON(
            [entryJSON(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                childId: child, occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
            )],
            cursor: "always-more"
        )
        performer.on("/entries") { _ in (stuck, 200) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()
        await model.loadMoreIfNeeded()
        await model.loadMoreIfNeeded()

        #expect(model.reachedEnd, "the floor stopped moving, so there is nothing older")
        #expect(performer.count(for: "/entries") == 2)
    }

    @Test("a page that fails leaves a quiet note and keeps whatever is already cached")
    func failureKeepsTheCache() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        let good = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: Date())],
            cursor: "cursor-one"
        )
        let boom = Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8)
        performer.on("/entries") { hit in hit == 1 ? (good, 200) : (boom, 500) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()

        #expect(model.notice != nil)
        // The archive is already on screen. A failed refetch must never blank it.
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)
    }

    @Test("a locally created entry is in the timeline before the server has heard of it")
    func localEntryAppearsImmediately() async throws {
        let context = try makeContext()
        let child = UUID()
        let local = Entry(childId: child, occurredAt: Date(), body: "written on a train")
        context.insert(local)
        try context.save()

        let performer = StubPerformer()
        let empty = pageJSON([], cursor: nil)
        performer.on("/entries") { _ in (empty, 200) }
        await TimelineModel(childId: child, api: client(performer), context: context).start()

        // The list's own predicate. Whether the server has heard about it is a fact about the
        // network, not about the archive.
        let visible = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil }
        ))
        #expect(visible.count == 1)
        #expect(visible.first?.sync == .pending)
    }

    @Test("a backdated entry sorts by when it happened, not by when it was written")
    func sortsByOccurredAt() async throws {
        let context = try makeContext()
        let child = UUID()
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let longAgo = Date(timeIntervalSince1970: 1_500_000_000)

        // A 2017 photo, added tonight. `created_at` is now; `occurred_at` is 2017.
        let performer = StubPerformer()
        let page = pageJSON(
            [
                entryJSON(id: UUID(), childId: child, occurredAt: now, body: "tonight"),
                entryJSON(
                    id: UUID(), childId: child, occurredAt: longAgo, createdAt: now,
                    body: "a photo from years ago, imported tonight"
                ),
            ],
            cursor: nil
        )
        performer.on("/entries") { _ in (page, 200) }
        await TimelineModel(childId: child, api: client(performer), context: context).start()

        let ordered = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        ))
        #expect(ordered.first?.body == "tonight")
        #expect(ordered.last?.body == "a photo from years ago, imported tonight")
        // Both were written at the same moment. Only `occurred_at` separates them.
        #expect(ordered.allSatisfy { abs($0.createdAt.timeIntervalSince(now)) < 1 })
    }
}
