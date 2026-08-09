import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The three defects the sync pull exists to close.
///
/// Each was real and documented before this engine existed, and each is written here as the
/// symptom rather than as a call to the code that fixes it — a test that asserts "the engine ran"
/// would keep passing if the engine ran and did the wrong thing.
///
/// All three are invisible on one device with one parent. They become correctness-critical the
/// moment a second parent is on the same child.
@MainActor
@Suite("Sync — the three defects")
struct SyncDefectTests {

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
        state: SyncStateStoring = InMemorySyncStateStore(pullEnabled: true)
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

    /// Exactly what the Timeline screen queries: live rows for this child, newest by
    /// `occurred_at`. Asserted through the same predicate the screen builds rather than a
    /// hand-rolled one, so "disappears from the timeline" means what it says.
    private func timelineRows(childId: UUID, in context: ModelContext) throws -> [Entry] {
        try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entry.childId == childId && entry.deletedAt == nil
            },
            sortBy: [SortDescriptor(\Entry.occurredAt, order: .reverse)]
        ))
    }

    // MARK: Defect 1 — a deletion made elsewhere never arrived

    /// `GET /entries` is paginated, so absence from a page cannot be read as a deletion. The
    /// entry was only ever discovered as a 404 when someone opened it.
    @Test("an entry deleted on another device disappears here, and does not come back")
    func remoteDeletionPropagatesAndStaysGone() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let cached = try cachedEntry(childId: child, occurredAt: occurred, body: "deleted on the other phone",
                                     updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(cached)
        let survivor = try cachedEntry(childId: child, occurredAt: occurred, body: "still here",
                                       updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(survivor)
        try context.save()
        #expect(try timelineRows(childId: child, in: context).count == 2)

        let performer = StubPerformer()
        performer.on("/sync") { _ in
            (syncJSON(
                entries: [entryJSON(
                    id: cached.id, childId: child, occurredAt: occurred,
                    body: "deleted on the other phone",
                    updatedAt: deletedAt, deletedAt: deletedAt
                )],
                cursor: laggedCursor(newest: deletedAt)
            ), 200)
        }

        let first = engine(childId: child, performer: performer, context: context)
        await first.pull()

        let visible = try timelineRows(childId: child, in: context)
        #expect(visible.count == 1, "the deletion arrived as a row, which is the only way it can")
        #expect(visible.first?.id == survivor.id)
        // Soft, never hard: a removed row would make the deletion unsyncable onwards.
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 2)

        // And a later pull that no longer mentions it must not resurrect it. Absence means
        // nothing — that is the whole rule, stated from the other side.
        let performerAfter = StubPerformer()
        performerAfter.on("/sync") { _ in (syncJSON(cursor: laggedCursor(newest: deletedAt)), 200) }
        let afterwards = engine(childId: child, performer: performerAfter, context: context)
        await afterwards.pull()

        #expect(try timelineRows(childId: child, in: context).count == 1, "it stays gone")
        #expect(cached.deletedAt == deletedAt)
    }

    // MARK: Defect 2 — recompute-ages only reached the newest page

    /// `POST /children/{id}/recompute-ages` corrects the whole archive server-side, but the
    /// client could only re-read the newest page of `GET /entries`. Everything older kept a
    /// stale age indefinitely.
    ///
    /// The fixture spans several pages on purpose: at `TimelineModel.pageSize` of 50, a 130-entry
    /// archive is three pages, and page-one-only reconciliation would leave 80 rows wrong.
    @Test("recompute-ages reaches the whole archive, not just the newest page")
    func recomputeAgesReachesEveryPage() async throws {
        let context = try makeContext()
        let child = UUID()
        let count = 130
        #expect(count > TimelineModel.pageSize * 2, "the fixture has to span several pages to mean anything")

        // A year of entries, all carrying the age the server computed against the wrong birthday.
        var ids: [UUID] = []
        for index in 0..<count {
            let occurred = Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400)
            let entry = try cachedEntry(
                childId: child, occurredAt: occurred, body: "day \(index)", ageMonths: 62,
                updatedAt: Date(timeIntervalSince1970: 1_650_000_000)
            )
            context.insert(entry)
            ids.append(entry.id)
        }
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Entry>()).allSatisfy { $0.childAgeMonths == 62 })

        // The birthday was corrected and every stored age recomputed. `updated_at` moves on all
        // of them, which is exactly what `/sync` filters on.
        let recomputedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = ids.enumerated().map { index, id in
            entryJSON(
                id: id, childId: child,
                occurredAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400),
                body: "day \(index)", ageMonths: 50, updatedAt: recomputedAt
            )
        }
        let performer = StubPerformer()
        performer.on("/sync") { _ in (syncJSON(entries: rows, cursor: laggedCursor(newest: recomputedAt)), 200) }

        let engine = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await engine.pull().plan)

        let stored = try context.fetch(FetchDescriptor<Entry>())
        #expect(stored.count == count)
        #expect(stored.allSatisfy { $0.childAgeMonths == 50 },
                "every entry, including the ones no page-one refetch would ever reach")
        #expect(plan.count(.entry, .update) == count)

        // The oldest row is the one a paginated refetch never got to. Named explicitly, because
        // "all of them" passing by accident on a small fixture is how this defect survived.
        let oldest = try #require(stored.min { $0.occurredAt < $1.occurredAt })
        #expect(oldest.childAgeMonths == 50)
    }

    // MARK: Defect 3 — assignment status had nowhere to converge

    @Test("assignment status converges from the server without reverting a local completion")
    func assignmentStatusConverges() async throws {
        let context = try makeContext()
        let child = UUID()
        let mine = UUID()
        let theirs = UUID()
        let updated = Date(timeIntervalSince1970: 1_700_000_000)

        // One assignment completed on this phone and not yet pushed; one completed by the other
        // parent, which this phone has never heard about.
        let completion = Entry(childId: child, assignmentId: mine, occurredAt: Date(), body: "we did it")
        context.insert(completion)
        for id in [mine, theirs] {
            context.insert(Assignment(
                id: id, childId: child, slot: "mission", body: "Take a photo", kind: "photo",
                completionMode: "media", status: AssignmentStatus.pending.rawValue,
                assignedOn: "2026-08-08", updatedAt: Date(timeIntervalSince1970: 1_690_000_000)
            ))
        }
        // The local one is done here already, exactly as the composer leaves it.
        try #require(SyncEngine.assignment(id: mine, in: context)).assignmentStatus = .done
        try context.save()

        let performer = StubPerformer()
        performer.on("/sync") { _ in
            (syncJSON(
                assignments: [
                    // The server has not heard about the local completion yet.
                    syncAssignmentJSON(id: mine, childId: child, status: "pending", updatedAt: updated),
                    // And the other parent's completion, which must land.
                    syncAssignmentJSON(id: theirs, childId: child, status: "done", updatedAt: updated),
                ],
                cursor: laggedCursor(newest: updated)
            ), 200)
        }

        let converging = engine(childId: child, performer: performer, context: context)
        let plan = try #require(await converging.pull().plan)

        #expect(try #require(SyncEngine.assignment(id: mine, in: context)).assignmentStatus == .done,
                "a pull must never revert a locally-completed mission to pending")
        #expect(try #require(SyncEngine.assignment(id: theirs, in: context)).assignmentStatus == .done,
                "and it must still converge on what the other parent did")
        #expect(plan.count(.assignment, .skippedLocalPending) == 1)
        #expect(plan.count(.assignment, .update) == 1)

        // Convergence completes once the push lands: the server now says done, the conflict stops
        // firing, and the two sides agree without anything having been reverted in between.
        let later = Date(timeIntervalSince1970: 1_750_000_000)
        let afterPush = StubPerformer()
        afterPush.on("/sync") { _ in
            (syncJSON(
                assignments: [syncAssignmentJSON(id: mine, childId: child, status: "done", updatedAt: later)],
                cursor: laggedCursor(newest: later)
            ), 200)
        }
        let reconciling = engine(childId: child, performer: afterPush, context: context)
        let settled = try #require(await reconciling.pull().plan)

        #expect(try #require(SyncEngine.assignment(id: mine, in: context)).assignmentStatus == .done)
        #expect(settled.conflicts.isEmpty, "nothing left to disagree about")
    }

    // MARK: The path this must not break

    /// Media deletion already worked, through the live media list every entry response carries.
    /// Adding the `/sync` path must not disturb it.
    @Test("media deleted elsewhere still leaves through the entry's live list")
    func inlineMediaDeletionStillWorks() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let cached = try cachedEntry(childId: child, occurredAt: occurred,
                                     updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(cached)
        let removed = completeMedia(entryId: cached.id)
        context.insert(removed)
        try context.save()

        // The entry comes back updated, and its media list — which is live-only — no longer
        // mentions the photo. Absence *is* information on this one path.
        let performer = StubPerformer()
        performer.on("/sync") { _ in
            (syncJSON(
                entries: [entryJSON(
                    id: cached.id, childId: child, occurredAt: occurred,
                    body: "still here", media: [], updatedAt: newest
                )],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }

        let engine = engine(childId: child, performer: performer, context: context)
        await engine.pull()

        #expect(removed.deletedAt != nil, "the inline-list path still marks it")
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == 1, "soft, as always")
    }
}
