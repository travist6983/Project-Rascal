import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The Settings surface for the pull: what it says, and what its two buttons do.
///
/// The wording is tested rather than eyeballed because this screen is the only place in the app
/// that mentions sync at all, and the morning sequence it exists for — read the position, run the
/// dry run, read the report, flip the switch — is only as good as the sentences in it.
@MainActor
@Suite("Settings — sync pull")
struct SyncPullSettingsTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func engine(
        childId: UUID,
        performer: StubPerformer,
        context: ModelContext,
        state: SyncStateStoring
    ) -> SyncEngine {
        SyncEngine(
            childId: childId,
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            context: context,
            state: state
        )
    }

    // MARK: The switch

    @Test("the toggle is off before anyone touches it, and the rows say so")
    func togglesOffByDefault() throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore()
        let model = SyncStatusModel(engine: engine(
            childId: child, performer: StubPerformer(), context: context, state: state
        ))

        #expect(model.pullEnabledBinding.wrappedValue == false)
        // **Was `== "Off"`, and that assertion pinned the defect rather than the behaviour.**
        // "Last pull" is a row whose value is a time; "Off" is the state of the toggle three rows
        // below it. The value now answers the question the label asks, and names the reason a
        // time cannot exist rather than leaving an empty fact on screen.
        #expect(model.lastPullDescription == "Never — pulling is off")
        #expect(model.cursorDescription == nil, "no position row while it is off")
    }

    @Test("flipping the toggle reaches the store the engine reads")
    func toggleWritesThrough() throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore()
        let engine = engine(childId: child, performer: StubPerformer(), context: context, state: state)
        let model = SyncStatusModel(engine: engine)

        model.pullEnabledBinding.wrappedValue = true

        #expect(state.pullEnabled)
        #expect(engine.pullEnabled)
        #expect(model.lastPullDescription == "Never", "on, but nothing has landed yet")
        #expect(model.cursorDescription == "Nothing stored — the next sync reads everything")
    }

    // MARK: The dry run

    @Test("a dry run fills the card and the report without touching the store")
    func dryRunProducesACardAndAReport() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore()

        let body = syncJSON(
            entries: [
                entryJSON(id: UUID(), childId: child, occurredAt: newest, body: "one"),
                entryJSON(id: UUID(), childId: child, occurredAt: newest, body: "two"),
            ],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }

        let model = SyncStatusModel(engine: engine(
            childId: child, performer: performer, context: context, state: state
        ))
        await model.runDryRun()

        guard case .ready(let summary) = model.dryRun else {
            Issue.record("expected a finished dry run, got \(model.dryRun)")
            return
        }
        #expect(summary == "2 to add.")
        #expect(model.report?.contains("SYNC DRY RUN — nothing was written") == true)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 0)
        #expect(state.cursor(for: child) == nil)
    }

    @Test("a dry run with nothing to do says so rather than showing zeroes")
    func dryRunWithNothingToDo() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/sync") { _ in (syncJSON(cursor: Date(timeIntervalSince1970: 1_700_000_000)), 200) }

        let model = SyncStatusModel(engine: engine(
            childId: child, performer: performer, context: context, state: InMemorySyncStateStore()
        ))
        await model.runDryRun()

        #expect(model.dryRun == .ready("Nothing to change — this device already has everything the server sent."))
    }

    @Test("the card names deletions, skips, and anomalies separately")
    func summaryNamesTheThingsWorthReading() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let doomed = try cachedEntry(childId: child, occurredAt: occurred, body: "would go",
                                     updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(doomed)
        let mine = try cachedEntry(childId: child, occurredAt: occurred, body: "mine",
                                   updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(mine)
        mine.sync = .pending
        try context.save()

        let body = syncJSON(
            entries: [
                entryJSON(id: doomed.id, childId: child, occurredAt: occurred, body: "would go",
                          updatedAt: newest, deletedAt: newest),
                entryJSON(id: mine.id, childId: child, occurredAt: occurred, body: "theirs",
                          updatedAt: newest),
            ],
            media: [syncMediaJSON(entryId: UUID())],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }

        let model = SyncStatusModel(engine: engine(
            childId: child, performer: performer, context: context, state: InMemorySyncStateStore()
        ))
        await model.runDryRun()

        guard case .ready(let summary) = model.dryRun else {
            Issue.record("expected a finished dry run, got \(model.dryRun)")
            return
        }
        #expect(summary.contains("1 to add"))
        #expect(summary.contains("1 to remove"))
        #expect(summary.contains("1 left alone because this phone has newer changes"))
        #expect(summary.contains("didn't understand — read the report"))
    }

    @Test("a failed dry run keeps what it managed to work out")
    func failedDryRunKeepsThePartialPlan() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/sync") { _ in
            (Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8), 500)
        }

        let model = SyncStatusModel(engine: engine(
            childId: child, performer: performer, context: context, state: InMemorySyncStateStore()
        ))
        await model.runDryRun()

        guard case .failed(let message) = model.dryRun else {
            Issue.record("expected a failed dry run, got \(model.dryRun)")
            return
        }
        #expect(!message.isEmpty)
        #expect(model.report != nil, "how far it got is more useful than the message alone")
    }

    // MARK: Reset

    @Test("resetting the position clears the cursor and the row says what that means")
    func resetClearsTheCursor() throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore(pullEnabled: true)
        state.setCursor(Date(timeIntervalSince1970: 1_700_000_000), for: child)

        let model = SyncStatusModel(engine: engine(
            childId: child, performer: StubPerformer(), context: context, state: state
        ))
        #expect(model.cursorDescription?.contains("Nothing stored") == false)

        model.resetCursor()

        #expect(state.cursor(for: child) == nil)
        #expect(model.cursorDescription == "Nothing stored — the next sync reads everything")
    }

    @Test("a failure is reported on this screen and nowhere else")
    func lastErrorSurfacesInSettings() async throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore(pullEnabled: true)
        let performer = StubPerformer()
        performer.on("/sync") { _ in
            (Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8), 500)
        }
        let engine = engine(childId: child, performer: performer, context: context, state: state)
        let model = SyncStatusModel(engine: engine)

        #expect(model.lastErrorDescription == nil)
        await engine.pull()

        // Nothing on Today or Timeline mentions this. The count of screens that scold is zero.
        #expect(model.lastErrorDescription != nil)
    }

    @Test("a successful pull clears the previous failure rather than stacking on it")
    func successClearsTheError() async throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore(pullEnabled: true)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let good = syncJSON(cursor: laggedCursor(newest: newest))

        let performer = StubPerformer()
        performer.on("/sync") { hit in
            hit == 1
                ? (Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8), 500)
                : (good, 200)
        }
        let engine = engine(childId: child, performer: performer, context: context, state: state)

        await engine.pull()
        #expect(engine.lastError != nil)

        await engine.pull()
        #expect(engine.lastError == nil)
        #expect(engine.lastSuccess != nil)
    }
}
