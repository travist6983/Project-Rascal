import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The client's half of sync.
///
/// The assertions here are the specification. Where one of them and the implementation disagree,
/// the assertion is right — that has been true three times on this project, and every rule these
/// cover is one whose failure mode is silent data loss rather than a visible bug.
@MainActor
@Suite("Sync engine")
struct SyncEngineTests {

    // MARK: Scaffolding

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

    private func engine(
        childId: UUID,
        performer: StubPerformer,
        context: ModelContext,
        state: SyncStateStoring = InMemorySyncStateStore(pullEnabled: true),
        hooks: SyncEngine.Hooks = SyncEngine.Hooks()
    ) -> SyncEngine {
        SyncEngine(
            childId: childId,
            api: client(performer),
            context: context,
            state: state,
            hooks: hooks
        )
    }

    /// The `since` query parameter of every `/sync` request, in order. Nil means a full pull.
    private func sinceParams(_ performer: StubPerformer) -> [String?] {
        performer.requests
            .filter { $0.url?.path().contains("/sync") ?? false }
            .map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "since" }?.value
            }
    }

    /// A performer that answers `/sync` with the same batch every round.
    ///
    /// This *is* the overlap window's behaviour rather than a simplification of it: with rows
    /// present the server returns `max(updated_at) - 30s`, so the second round re-reads the lag
    /// band, finds the same maximum, and hands back the identical cursor.
    private func steadyPerformer(_ body: Data) -> StubPerformer {
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        return performer
    }

    private func entries(in context: ModelContext) throws -> [Entry] {
        try context.fetch(FetchDescriptor<Entry>())
    }

    // MARK: 1 — Cold start

    @Test("a nil cursor pulls everything, and asks for no window at all")
    func coldStartPullsEverything() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let entryId = UUID()

        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: entryId, childId: child, occurredAt: newest, body: "first")],
            media: [syncMediaJSON(entryId: entryId)],
            assignments: [syncAssignmentJSON(childId: child)],
            cursor: laggedCursor(newest: newest)
        ))

        let engine = engine(childId: child, performer: performer, context: context)
        let outcome = await engine.pull()

        let plan = try #require(outcome.plan)
        #expect(sinceParams(performer).first == .some(nil), "a cold start asks for no window")
        #expect(plan.cursorBefore == nil)
        #expect(try entries(in: context).count == 1)
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Assignment>()) == 1)
        #expect(engine.cursor == laggedCursor(newest: newest))
    }

    // MARK: 2 — Recovery

    @Test("a cursor that cannot be read is treated as absent, and the next pull is a full one")
    func corruptCursorRecoversByPullingFromZero() async throws {
        let context = try makeContext()
        let child = UUID()
        let suite = "sync-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Half-written, foreign, or from a build that stored something else. Whatever the cause,
        // honouring it would skip every record before it, permanently and silently.
        defaults.set("not a timestamp", forKey: "sync.cursor.\(child.uuidString)")
        let store = UserDefaultsSyncStateStore(defaults: defaults)
        store.pullEnabled = true

        #expect(store.cursor(for: child) == nil, "an unparseable cursor is not a position")

        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: laggedCursor(newest: newest)
        ))

        let engine = engine(childId: child, performer: performer, context: context, state: store)
        await engine.pull()

        #expect(sinceParams(performer).first == .some(nil), "recovery is a pull from zero")
        #expect(try entries(in: context).count == 1)
        #expect(store.cursor(for: child) == laggedCursor(newest: newest), "and it stores a usable one")
    }

    @Test("resetting the cursor forces the next pull to read the whole archive")
    func resetCursorForcesFullPull() async throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore(pullEnabled: true)
        state.setCursor(Date(timeIntervalSince1970: 1_600_000_000), for: child)

        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let performer = steadyPerformer(syncJSON(cursor: laggedCursor(newest: newest)))
        let engine = engine(childId: child, performer: performer, context: context, state: state)

        engine.resetCursor()
        #expect(engine.cursor == nil)
        await engine.pull()

        #expect(sinceParams(performer).first == .some(nil))
    }

    // MARK: 3 — Idempotency

    @Test("the overlap window re-delivers records, and applying them twice changes nothing")
    func overlapReDeliveryIsIdempotent() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let entryId = UUID()
        let mediaId = UUID()
        let assignmentId = UUID()

        let batch = syncJSON(
            entries: [entryJSON(
                id: entryId, childId: child, occurredAt: newest,
                body: "he called it a hangaburger", tags: ["humor"]
            )],
            media: [syncMediaJSON(id: mediaId, entryId: entryId)],
            assignments: [syncAssignmentJSON(id: assignmentId, childId: child)],
            tags: [syncTagJSON(entryId: entryId, name: "humor")],
            cursor: laggedCursor(newest: newest)
        )
        let performer = steadyPerformer(batch)
        let engine = engine(childId: child, performer: performer, context: context)

        let first = await engine.pull()
        let firstPlan = try #require(first.plan)
        // Two rounds is the normal finish: round one reads, round two closes the lag gap, and the
        // identical cursor coming back is what stops the loop.
        #expect(firstPlan.rounds == 2)
        #expect(firstPlan.reDeliveredAcrossRounds > 0, "the window re-delivers by design")

        let after = try snapshot(context)
        #expect(after.count == 4, "one entry, one media, one assignment, one tag name")

        // Now pull the whole thing again from scratch — the case a relaunch produces.
        let second = await engine.pull()
        let secondPlan = try #require(second.plan)

        #expect(try snapshot(context) == after, "a second pull of the same records changes nothing")
        #expect(secondPlan.count(.insert) == 0)
        #expect(secondPlan.count(.update) == 0)
        #expect(secondPlan.count(.softDelete) == 0)
        #expect(secondPlan.isNoOp, "everything was already held")
    }

    /// Every field the engine can write, flattened to comparable strings.
    ///
    /// Compared as values rather than by counting rows: "nothing changed" has to mean no field
    /// moved, not merely that no row appeared. A count-only assertion would pass while an apply
    /// quietly rewrote a body on every pull.
    private func snapshot(_ context: ModelContext) throws -> [String] {
        var lines: [String] = []
        for entry in try context.fetch(FetchDescriptor<Entry>()) {
            lines.append("""
            entry \(entry.id) \(entry.title ?? "-") \(entry.body ?? "-") \(entry.occurredAt) \
            \(entry.createdAt) \(entry.updatedAt) \(entry.deletedAt?.description ?? "-") \
            \(entry.entryType ?? "-") \(entry.childAgeMonths?.description ?? "-") \
            \(entry.syncState) \(entry.existsOnServer) \(entry.deletionPending) \
            \(entry.serverMediaCount)
            """)
            for name in entry.tagNames.sorted() { lines.append("tag \(entry.id) \(name)") }
        }
        for media in try context.fetch(FetchDescriptor<Media>()) {
            lines.append("""
            media \(media.id) \(media.entryId) \(media.kind) \(media.uploadState) \
            \(media.s3Key ?? "-") \(media.byteCount) \(media.deletedAt?.description ?? "-") \
            \(media.transcript ?? "-") \(media.updatedAt)
            """)
        }
        for assignment in try context.fetch(FetchDescriptor<Assignment>()) {
            lines.append("""
            assignment \(assignment.id) \(assignment.status) \(assignment.body) \
            \(assignment.slot) \(assignment.updatedAt) \(assignment.completedBy?.uuidString ?? "-")
            """)
        }
        return lines.sorted()
    }

    // MARK: 4 and 5 — The pending-local rule

    @Test("a local edit that has not been pushed survives a pull carrying the server's older copy")
    func localPendingSurvivesAPull() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let serverVersion = Date(timeIntervalSince1970: 1_650_000_000)

        // Synced from the server, then edited here and not yet pushed.
        let local = try cachedEntry(childId: child, occurredAt: occurred, body: "the old text",
                                    updatedAt: serverVersion)
        context.insert(local)
        local.body = "the edit made on the train"
        local.sync = .pending
        try context.save()

        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(
                id: local.id, childId: child, occurredAt: occurred,
                body: "the old text", updatedAt: newest
            )],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let outcome = await engine.pull()
        let plan = try #require(outcome.plan)

        // Even though the server's row is strictly newer by `updated_at`.
        #expect(local.body == "the edit made on the train", "the push queue wins, always")
        #expect(plan.count(.entry, .skippedLocalPending) == 1)
        #expect(plan.conflicts.count == 1)
        #expect(plan.conflicts.first?.winner == .local)
    }

    @Test("once the push lands, the next pull reconciles the row normally")
    func localPendingReconcilesAfterAPush() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, occurredAt: occurred, body: "the old text",
                                    updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(local)
        local.body = "the edit made on the train"
        local.sync = .pending
        try context.save()

        // The server now agrees, because the push landed. `applyServerResponse` is what a
        // successful push does to the row, so this is that, not a stand-in for it.
        let pushed = try decodeEntry(entryJSON(
            id: local.id, childId: child, occurredAt: occurred,
            body: "the edit made on the train", updatedAt: newest
        ))
        local.applyServerResponse(pushed)
        try context.save()
        #expect(local.sync == .synced)

        // A later pull carrying a change made on *another* device now applies, because there is
        // nothing local outstanding to protect.
        let later = Date(timeIntervalSince1970: 1_750_000_000)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(
                id: local.id, childId: child, occurredAt: occurred,
                body: "renamed on the other phone", updatedAt: later
            )],
            cursor: laggedCursor(newest: later)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(local.body == "renamed on the other phone")
        #expect(plan.count(.entry, .update) == 1)
        #expect(plan.conflicts.isEmpty)
    }

    // MARK: 6 — Today's standing rule

    @Test("a pull does not revert a locally-completed mission to pending")
    func localCompletionIsNotReverted() async throws {
        let context = try makeContext()
        let child = UUID()
        let assignmentId = UUID()
        let updated = Date(timeIntervalSince1970: 1_700_000_000)

        // Completed on this phone a moment ago; the server has not heard yet.
        let completion = Entry(childId: child, assignmentId: assignmentId, occurredAt: Date(), body: "done it")
        context.insert(completion)
        context.insert(Assignment(
            id: assignmentId, childId: child, slot: "mission", body: "Take a photo",
            kind: "photo", completionMode: "media", status: AssignmentStatus.done.rawValue,
            assignedOn: "2026-08-08", updatedAt: Date(timeIntervalSince1970: 1_690_000_000)
        ))
        try context.save()

        let performer = steadyPerformer(syncJSON(
            assignments: [syncAssignmentJSON(
                id: assignmentId, childId: child, status: "pending", updatedAt: updated
            )],
            cursor: laggedCursor(newest: updated)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        let stored = try #require(SyncEngine.assignment(id: assignmentId, in: context))
        #expect(stored.assignmentStatus == .done, "the parent did it; the network is a separate fact")
        #expect(plan.count(.assignment, .skippedLocalPending) == 1)
        #expect(plan.conflicts.first?.winner == .local)

        // And the board agrees, which is the surface this rule exists to protect.
        let board = TodayBoard.merge(
            response: TodayResponse(
                date: "2026-08-08",
                child: ChildSummary(id: child, name: "Rascal", ageMonths: 62),
                today: [AssignmentResponse(
                    id: assignmentId, slot: "mission", body: "Take a photo", kind: "photo",
                    completionMode: "media", theme: nil, status: .pending,
                    assignedOn: "2026-08-08", expiresOn: "2026-08-22", promptId: nil,
                    isCustom: false, unlockAtAge: nil
                )],
                waiting: [], doneToday: []
            ),
            entries: [completion],
            media: []
        )
        #expect(board.today.isEmpty)
        #expect(board.doneToday.count == 1)
    }

    @Test("a server completion this phone knows nothing about does apply")
    func serverCompletionApplies() async throws {
        let context = try makeContext()
        let child = UUID()
        let assignmentId = UUID()
        let updated = Date(timeIntervalSince1970: 1_700_000_000)
        let completer = UUID()

        context.insert(Assignment(
            id: assignmentId, childId: child, slot: "mission", body: "Take a photo",
            kind: "photo", completionMode: "media", status: AssignmentStatus.pending.rawValue,
            assignedOn: "2026-08-08", updatedAt: Date(timeIntervalSince1970: 1_690_000_000)
        ))
        try context.save()

        let performer = steadyPerformer(syncJSON(
            assignments: [syncAssignmentJSON(
                id: assignmentId, childId: child, status: "done",
                completedBy: completer, updatedAt: updated
            )],
            cursor: laggedCursor(newest: updated)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        let stored = try #require(SyncEngine.assignment(id: assignmentId, in: context))
        #expect(stored.assignmentStatus == .done)
        #expect(stored.completedBy == completer)
        #expect(plan.count(.assignment, .update) == 1)
    }

    // MARK: 7 — Deletions

    @Test("a deletion row sets deleted_at and the SwiftData row still exists")
    func deletionIsSoftAndTheRowRemains() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, occurredAt: occurred, body: "gone tomorrow",
                                    updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(local)
        let attached = completeMedia(entryId: local.id)
        context.insert(attached)
        try context.save()

        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(
                id: local.id, childId: child, occurredAt: occurred, body: "gone tomorrow",
                updatedAt: deletedAt, deletedAt: deletedAt
            )],
            cursor: laggedCursor(newest: deletedAt)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(try entries(in: context).count == 1, "the row stays — a hard delete is unsyncable")
        #expect(local.deletedAt == deletedAt)
        #expect(attached.deletedAt != nil, "its media carries its own deleted_at, as the server does")
        #expect(plan.count(.entry, .softDelete) == 1)
        #expect(plan.deletions.count == 1)
        #expect(plan.deletions.first?.preview == "gone tomorrow")
        #expect(plan.deletions.first?.occurredAt == occurred, "listed by when it happened")
    }

    @Test("a deletion already applied is unchanged rather than applied twice")
    func deletionDoesNotResurrectOrRepeat() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, occurredAt: occurred, updatedAt: occurred)
        context.insert(local)
        try context.save()

        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(
                id: local.id, childId: child, occurredAt: occurred,
                updatedAt: deletedAt, deletedAt: deletedAt
            )],
            cursor: laggedCursor(newest: deletedAt)
        ))
        let engine = engine(childId: child, performer: performer, context: context)

        await engine.pull()
        let stamp = local.deletedAt
        let plan = try #require(await engine.pull().plan)

        #expect(local.deletedAt == stamp, "the deletion stamp does not move on a re-delivery")
        #expect(plan.count(.entry, .softDelete) == 0)
        #expect(plan.count(.entry, .unchanged) == 1)
    }

    @Test("a media row deleted elsewhere is soft-deleted here")
    func mediaDeletionApplies() async throws {
        let context = try makeContext()
        let child = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
        context.insert(local)
        let attached = completeMedia(entryId: local.id)
        context.insert(attached)
        try context.save()

        let performer = steadyPerformer(syncJSON(
            media: [syncMediaJSON(id: attached.id, entryId: local.id, deletedAt: deletedAt)],
            cursor: laggedCursor(newest: deletedAt)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(attached.deletedAt == deletedAt)
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == 1, "soft only")
        #expect(plan.count(.media, .softDelete) == 1)
    }

    // MARK: 8 — Ordering within a batch

    @Test("a media row arriving alongside an entry this device has never held is applied, not dropped")
    func mediaIsAppliedAfterItsEntryInTheSameBatch() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let entryId = UUID()
        let mediaId = UUID()

        // Media listed *before* entries in the JSON, to prove the ordering is the engine's and
        // not the server's. Entries are applied first by construction.
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: entryId, childId: child, occurredAt: newest, type: "photo")],
            media: [syncMediaJSON(id: mediaId, entryId: entryId)],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(EntryCache.media(id: mediaId, in: context) != nil)
        #expect(plan.anomalies.contains { $0.kind == .mediaWithoutEntry } == false,
                "its entry was in the same batch, so this is ordinary")
    }

    @Test("a media row whose entry is nowhere is still applied, and reported loudly")
    func orphanedMediaIsReportedNotDropped() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let mediaId = UUID()

        let performer = steadyPerformer(syncJSON(
            media: [syncMediaJSON(id: mediaId, entryId: UUID())],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(EntryCache.media(id: mediaId, in: context) != nil, "applied anyway — never dropped")
        #expect(plan.anomalies.contains { $0.kind == .mediaWithoutEntry })
        #expect(plan.report().contains("media whose entry is unknown"))
    }

    // MARK: 9 — Rollback

    @Test("a failure mid-apply rolls the batch back and leaves the cursor where it was")
    func midApplyFailureRollsBack() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore(pullEnabled: true)
        let before = Date(timeIntervalSince1970: 1_600_000_000)
        state.setCursor(before, for: child)

        struct Boom: Error {}
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(
            childId: child, performer: performer, context: context, state: state,
            hooks: SyncEngine.Hooks(beforeSave: { _ in throw Boom() })
        )

        let outcome = await engine.pull()

        #expect(outcome.errorMessage != nil)
        #expect(try entries(in: context).isEmpty, "the round's changes are discarded whole")
        #expect(state.cursor(for: child) == before,
                "a partial advance would lose those records permanently and silently")
        #expect(state.lastError(for: child) != nil)
    }

    @Test("a network failure on a later round keeps the cursor at the last clean round")
    func laterRoundFailureDoesNotAdvancePastIt() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore(pullEnabled: true)

        let performer = StubPerformer()
        let round1 = syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        performer.on("/sync") { hit in hit == 1 ? (round1, 200) : (Data("nonsense".utf8), 500) }

        let engine = engine(childId: child, performer: performer, context: context, state: state)
        let outcome = await engine.pull()

        #expect(outcome.errorMessage != nil)
        #expect(try entries(in: context).count == 1, "round one applied and was saved")
        #expect(state.cursor(for: child) == laggedCursor(newest: newest),
                "the cursor sits at the last round that applied cleanly, not beyond it")
    }

    @Test("a failed pull leaves the cursor untouched and is silent to the parent")
    func networkFailureIsSilentAndPositionless() async throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore(pullEnabled: true)

        let performer = StubPerformer()
        performer.on("/sync") { _ in (Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8), 500) }

        let engine = engine(childId: child, performer: performer, context: context, state: state)
        let outcome = await engine.pull()

        #expect(outcome.errorMessage != nil)
        #expect(state.cursor(for: child) == nil)
        #expect(state.lastSuccess(for: child) == nil)
        #expect(engine.lastError != nil, "Settings is where it surfaces, and nowhere else")
    }

    // MARK: 10 — Termination

    @Test("the round loop stops as soon as the cursor stops advancing")
    func loopStopsWhenTheCursorRepeats() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: laggedCursor(newest: newest)
        ))

        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(plan.rounds == 2, "one to read, one to close the lag gap")
        #expect(performer.count(for: "/sync") == 2)
    }

    private func limitParams(_ performer: StubPerformer) -> [String?] {
        performer.requests
            .filter { $0.url?.path().contains("/sync") ?? false }
            .map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "limit" }?.value
            }
    }

    @Test("has_more is a key this client models, not an anomaly")
    func hasMoreIsKnown() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: laggedCursor(newest: newest),
            hasMore: false
        ))

        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(
            plan.anomalies.filter { $0.kind == .unknownResponseKey }.isEmpty,
            "the server has sent has_more since Aug 13, 2026; a client reporting it as unknown was reporting its own gap"
        )
        #expect(plan.rounds == 2, "the ordinary two-round finish is untouched")
    }

    @Test("a stalled cursor with more to fetch asks for a bigger page instead of stopping")
    func aStalledPageGrows() async throws {
        // **The hole.** Three entries restamped inside one 30-second window — a birthdate
        // correction does this to a whole archive in one transaction — and a server page that
        // holds two of them. The lagged cursor lands back inside the window, so the second call
        // returns the same page and the same cursor: before phase 141 the loop read that as
        // "done", persisted the cursor, and the third entry was never delivered.
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = [UUID(), UUID(), UUID()]
        let page = ids.prefix(2).map { entryJSON(id: $0, childId: child, occurredAt: newest) }
        let whole = ids.map { entryJSON(id: $0, childId: child, occurredAt: newest) }
        let cursor = laggedCursor(newest: newest)

        let performer = StubPerformer()
        performer.on("/sync") { call in
            // Calls 1 and 2 are the default page, cut; call 3 carries the larger limit and is whole.
            call < 3
                ? (syncJSON(entries: page, cursor: cursor, hasMore: true), 200)
                : (syncJSON(entries: whole, cursor: cursor, hasMore: false), 200)
        }

        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        let stored = try entries(in: context)
        #expect(stored.count == 3, "the row past the page must reach the device")
        #expect(
            limitParams(performer) == [nil, nil, "2000"],
            "the default page twice, then the largest the server allows at the same position"
        )
        #expect(plan.rounds == 3)
        #expect(plan.anomalies.filter { $0.kind == .pagingStalled }.isEmpty)
    }

    @Test("a page that stalls even at the largest size is reported, not silently finished")
    func aStallAtTheLargestPageIsAnAnomaly() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let cursor = laggedCursor(newest: newest)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: cursor,
            hasMore: true
        ))

        let engine = engine(childId: child, performer: performer, context: context)
        let outcome = await engine.pull()
        let plan = try #require(outcome.plan)

        #expect(limitParams(performer) == [nil, nil, "2000"], "one escalation, then the stall is named")
        #expect(plan.rounds == 3)
        #expect(
            plan.anomalies.contains { $0.kind == .pagingStalled },
            "success with a hole in it is the outcome this exists to stop"
        )
        #expect(
            plan.report().contains("the cursor stalled with more to fetch"),
            "counted in the header and rendered nowhere beneath it is not reported"
        )
        #expect(outcome.errorMessage == nil, "what did arrive is still applied; the gap is reported")
    }

    @Test("a stall met on the last round is reported even though no round is left to grow into")
    func aStallOnTheLastRoundIsStillAnAnomaly() async throws {
        // Seven rounds with an advancing cursor — a fresh install paging through a large archive —
        // and then a page that stalls with more to fetch, on the round the cap makes the last one.
        // `continue` alone would end the loop with the cap check skipped and nothing recorded: a
        // clean report and a clean `lastSuccess` over a hole.
        let context = try makeContext()
        let child = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let last = SyncEngine.maxRounds
        let performer = StubPerformer()
        performer.on("/sync") { call in
            let newest = base.addingTimeInterval(Double(min(call, last - 1)) * 60)
            let more = call >= last - 1
            return (
                syncJSON(
                    entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
                    cursor: laggedCursor(newest: newest),
                    hasMore: more
                ),
                200
            )
        }

        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(plan.rounds == last)
        #expect(plan.anomalies.contains { $0.kind == .pagingStalled })
        #expect(plan.report().contains("the cursor stalled with more to fetch"))
        #expect(!limitParams(performer).contains("2000"), "no round was left to ask for a larger page")
    }

    @Test("an empty batch stops the loop even though its cursor advances")
    func emptyBatchStopsTheLoop() async throws {
        let context = try makeContext()
        let child = UUID()

        // The case that would spin forever if the loop tested only for cursor movement: with no
        // rows to take a maximum from, the server returns `now() - 30s`, which is always ahead of
        // whatever was sent.
        let performer = StubPerformer()
        performer.on("/sync") { hit in
            (syncJSON(cursor: Date().addingTimeInterval(Double(hit))), 200)
        }

        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(plan.rounds == 1)
        #expect(performer.count(for: "/sync") == 1)
    }

    @Test("a cursor that never stops advancing is capped, and the cap is reported")
    func pagingCapIsEnforcedAndReported() async throws {
        let context = try makeContext()
        let child = UUID()

        // A server whose cursor moves forever with rows always present. Without the cap this is
        // an unbounded request loop on a parent's cellular data.
        let performer = StubPerformer()
        performer.on("/sync") { hit in
            let newest = Date(timeIntervalSince1970: 1_700_000_000 + Double(hit) * 600)
            return (syncJSON(
                entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest, updatedAt: newest)],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }

        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(plan.rounds == SyncEngine.maxRounds)
        #expect(performer.count(for: "/sync") == SyncEngine.maxRounds)
        #expect(plan.anomalies.contains { $0.kind == .pagingCapReached })
        #expect(plan.report().contains("the paging cap was reached"))
    }

    // MARK: 11 — Coalescing

    @Test("four triggers at once are one pull, not four")
    func concurrentTriggersCoalesce() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)

        // Foreground, pull-to-refresh, post-push-drain, and Today's load, all landing together.
        async let a = engine.pull()
        async let b = engine.pull()
        async let c = engine.pull()
        async let d = engine.pull()
        let outcomes = await [a, b, c, d]

        #expect(outcomes.count == 4)
        #expect(performer.count(for: "/sync") == 2, "one pull's worth of rounds, not four")
        #expect(try entries(in: context).count == 1)
    }

    // MARK: 12 — Identity

    @Test("an entry created in the composer and then pulled back is one row, never two")
    func composerEntryDoesNotDuplicateOnPull() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        // Written locally, pushed, acknowledged — the composer's happy path.
        let composed = Entry(childId: child, occurredAt: occurred, body: "he called it a hangaburger")
        context.insert(composed)
        composed.applyServerResponse(try decodeEntry(entryJSON(
            id: composed.id, childId: child, occurredAt: occurred,
            body: "he called it a hangaburger", updatedAt: newest
        )))
        try context.save()

        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(
                id: composed.id, childId: child, occurredAt: occurred,
                body: "he called it a hangaburger", updatedAt: newest
            )],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(try entries(in: context).count == 1,
                "client-generated ids mean the composer's row and the server's are one row")
        #expect(plan.count(.entry, .insert) == 0)
    }

    // MARK: The flag

    @Test("with the flag off nothing is read and nothing is written")
    func disabledPullTouchesNothing() async throws {
        let context = try makeContext()
        let child = UUID()
        let state = InMemorySyncStateStore(pullEnabled: false)
        let performer = steadyPerformer(syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: Date())],
            cursor: Date()
        ))

        let engine = engine(childId: child, performer: performer, context: context, state: state)
        let outcome = await engine.pull()

        if case .disabled = outcome {} else { Issue.record("a pull with the flag off must be disabled") }
        #expect(performer.count(for: "/sync") == 0, "not even a request goes out")
        #expect(try entries(in: context).isEmpty)
        #expect(state.cursor(for: child) == nil)
    }

    @Test("the flag ships off")
    func flagDefaultsToOff() throws {
        let suite = "sync-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UserDefaultsSyncStateStore(defaults: defaults).pullEnabled == false)
    }

    // MARK: Tags

    @Test("a tag link folds onto the entry, and a removed one comes back off")
    func tagLinksFoldOntoTheEntry() async throws {
        let context = try makeContext()
        let child = UUID()
        let removedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, tags: ["humor", "food"],
                                    updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
        context.insert(local)
        try context.save()
        #expect(local.tagNames.sorted() == ["food", "humor"])

        let performer = steadyPerformer(syncJSON(
            tags: [
                syncTagJSON(entryId: local.id, name: "food", deletedAt: removedAt),
                syncTagJSON(entryId: local.id, name: "his-words"),
            ],
            cursor: laggedCursor(newest: removedAt)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(local.tagNames.sorted() == ["his-words", "humor"])
        #expect(plan.count(.tag, .softDelete) == 1)
        #expect(plan.count(.tag, .insert) == 1)
    }

    @Test("two tags on one entry are two planned changes, not one")
    func tagsOnOneEntryDoNotCollapse() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
        context.insert(local)
        try context.save()

        let performer = steadyPerformer(syncJSON(
            tags: [
                syncTagJSON(entryId: local.id, name: "humor"),
                syncTagJSON(entryId: local.id, name: "food"),
            ],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        // A tag link is keyed on the entry id, so without a discriminator these two collapse into
        // one planned change and the report undercounts.
        #expect(plan.count(.tag, .insert) == 2)
        #expect(local.tagNames.sorted() == ["food", "humor"])
    }

    // MARK: Anomalies

    @Test("an entity type this client does not model is named, not swallowed")
    func unknownResponseKeyIsReported() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let performer = steadyPerformer(syncJSON(
            cursor: laggedCursor(newest: newest),
            extraKeys: ["milestones": "[{\"id\":\"x\"}]"]
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(plan.anomalies.contains { $0.kind == .unknownResponseKey })
        #expect(plan.report().contains("milestones"))
    }

    @Test("the same id twice in one batch is named")
    func duplicateIdInOneBatchIsReported() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let twice = UUID()

        let performer = steadyPerformer(syncJSON(
            entries: [
                entryJSON(id: twice, childId: child, occurredAt: newest, body: "one"),
                entryJSON(id: twice, childId: child, occurredAt: newest, body: "two"),
            ],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(plan.anomalies.contains { $0.kind == .duplicateIdInBatch })
        #expect(try entries(in: context).count == 1)
    }

    @Test("a status this client has no case for is named rather than rendered as a guess")
    func unrecognisedStatusIsReported() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let performer = steadyPerformer(syncJSON(
            assignments: [syncAssignmentJSON(childId: child, status: "snoozed", updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(plan.anomalies.contains { $0.kind == .unrecognisedValue })
        #expect(try context.fetchCount(FetchDescriptor<Assignment>()) == 1,
                "still cached — an unknown value renders neutrally, it does not vanish")
    }

    // MARK: Media that is still uploading

    @Test("a file still uploading from this phone is not dragged backwards by the server's row")
    func inFlightMediaIsLeftAlone() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
        context.insert(local)
        let uploading = Media(entryId: local.id, kind: "photo", contentType: "image/jpeg", byteCount: 9_000)
        uploading.state = .uploading
        uploading.bytesSent = 4_000
        context.insert(uploading)
        try context.save()

        let performer = steadyPerformer(syncJSON(
            media: [syncMediaJSON(id: uploading.id, entryId: local.id, status: "pending", updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        #expect(uploading.state == .uploading)
        #expect(uploading.bytesSent == 4_000)
        #expect(plan.count(.media, .skippedLocalPending) == 1)
    }

    @Test("a media row the server still calls pending is not cached at all")
    func pendingServerMediaIsNotCached() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
        context.insert(local)
        try context.save()

        let performer = steadyPerformer(syncJSON(
            media: [syncMediaJSON(entryId: local.id, status: "pending", updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        ))
        let engine = engine(childId: child, performer: performer, context: context)
        await engine.pull()

        // A row with no bytes anywhere this device can reach would enter the upload sweep, hunt
        // for a staged file that was never here, and mark somebody else's healthy upload failed.
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == 0)
    }
}
