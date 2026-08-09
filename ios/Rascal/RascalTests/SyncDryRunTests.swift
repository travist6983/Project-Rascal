import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The dry run and the report it produces.
///
/// This is the thing a parent reads before letting the engine near a real archive, so the bar is
/// higher than "it compiles a summary": an undercount here is worse than an unfinished feature.
/// The assertions are about what the report *says*, not about what the engine did — a correct
/// engine with a lying report is the failure mode this suite exists to catch.
@MainActor
@Suite("Sync dry run")
struct SyncDryRunTests {

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
        state: SyncStateStoring = InMemorySyncStateStore(pullEnabled: false)
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

    /// Every field of every row, flattened. "Nothing was written" has to mean no value moved,
    /// not merely that no row appeared.
    private func snapshot(_ context: ModelContext) throws -> [String] {
        var lines: [String] = []
        for entry in try context.fetch(FetchDescriptor<Entry>()) {
            lines.append("""
            entry \(entry.id) \(entry.title ?? "-") \(entry.body ?? "-") \(entry.occurredAt) \
            \(entry.createdAt) \(entry.updatedAt) \(entry.deletedAt?.description ?? "-") \
            \(entry.entryType ?? "-") \(entry.childAgeMonths?.description ?? "-") \
            \(entry.syncState) \(entry.existsOnServer) \(entry.deletionPending) \
            \(entry.serverMediaCount) \(entry.tagNames.sorted().joined(separator: "|"))
            """)
        }
        for media in try context.fetch(FetchDescriptor<Media>()) {
            lines.append("""
            media \(media.id) \(media.entryId) \(media.uploadState) \(media.s3Key ?? "-") \
            \(media.deletedAt?.description ?? "-") \(media.updatedAt) \(media.bytesSent)
            """)
        }
        for assignment in try context.fetch(FetchDescriptor<Assignment>()) {
            lines.append("assignment \(assignment.id) \(assignment.status) \(assignment.updatedAt)")
        }
        return lines.sorted()
    }

    // MARK: 13 — It applies nothing

    @Test("a dry run leaves the store exactly as it found it")
    func dryRunAppliesNothing() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore(pullEnabled: false)

        // A store with something of everything in it, so a stray write has somewhere to show up.
        let doomed = try cachedEntry(childId: child, occurredAt: occurred, body: "would be deleted",
                                     tags: ["humor"], updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(doomed)
        let stale = try cachedEntry(childId: child, occurredAt: occurred, body: "would be updated",
                                    updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(stale)
        let photo = completeMedia(entryId: stale.id)
        context.insert(photo)
        context.insert(Assignment(
            id: UUID(), childId: child, slot: "mission", body: "Take a photo", kind: "photo",
            completionMode: "media", status: AssignmentStatus.pending.rawValue,
            assignedOn: "2026-08-08", updatedAt: Date(timeIntervalSince1970: 1_690_000_000)
        ))
        try context.save()

        let before = try snapshot(context)

        let body = syncJSON(
            entries: [
                entryJSON(id: doomed.id, childId: child, occurredAt: occurred,
                          body: "would be deleted", updatedAt: newest, deletedAt: newest),
                entryJSON(id: stale.id, childId: child, occurredAt: occurred,
                          body: "changed on the other phone", updatedAt: newest),
                entryJSON(id: UUID(), childId: child, occurredAt: occurred,
                          body: "brand new", updatedAt: newest),
            ],
            media: [syncMediaJSON(id: photo.id, entryId: stale.id, deletedAt: newest)],
            assignments: [syncAssignmentJSON(childId: child, updatedAt: newest)],
            tags: [syncTagJSON(entryId: doomed.id, name: "humor", deletedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }

        let engine = engine(childId: child, performer: performer, context: context, state: state)
        let outcome = await engine.dryRun()
        let plan = try #require(outcome.plan)

        #expect(try snapshot(context) == before, "not one field moved")
        #expect(state.cursor(for: child) == nil, "and the position did not move either")
        #expect(state.lastSuccess(for: child) == nil, "a dry run is not a successful sync")
        #expect(plan.isDryRun)
        #expect(plan.writeCount > 0, "it still worked out what it would have done")
    }

    @Test("a dry run runs with the flag off — that is the whole point of it")
    func dryRunIgnoresTheFlag() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore(pullEnabled: false)

        let body = syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }

        let plan = try #require(await engine(childId: child, performer: performer, context: context, state: state)
            .dryRun().plan)

        #expect(performer.count(for: "/sync") > 0, "a genuine GET /sync, not a simulation")
        #expect(plan.count(.entry, .insert) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 0)
    }

    @Test("a dry run and the pull that follows it agree")
    func dryRunPredictsTheRealThing() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore(pullEnabled: true)

        let body = syncJSON(
            entries: [
                entryJSON(id: UUID(), childId: child, occurredAt: newest, body: "one"),
                entryJSON(id: UUID(), childId: child, occurredAt: newest, body: "two"),
            ],
            assignments: [syncAssignmentJSON(childId: child, updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let engine = engine(childId: child, performer: performer, context: context, state: state)

        let predicted = try #require(await engine.dryRun().plan)
        let actual = try #require(await engine.pull().plan)

        // The dry run and the apply are the same code with one flag flipped, and this is the
        // assertion that keeps them that way.
        #expect(predicted.count(.entry, .insert) == actual.count(.entry, .insert))
        #expect(predicted.count(.assignment, .insert) == actual.count(.assignment, .insert))
        #expect(predicted.writeCount == actual.writeCount)
    }

    // MARK: The report

    @Test("the report lists every deletion in full, one by one")
    func reportListsEveryDeletion() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        // Enough that a summary would be tempting. Deletions are never summarised.
        var rows: [String] = []
        var previews: [String] = []
        for index in 0..<12 {
            let occurred = Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400)
            let body = "entry number \(index) that would go"
            let cached = try cachedEntry(childId: child, occurredAt: occurred, body: body,
                                         updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
            context.insert(cached)
            rows.append(entryJSON(id: cached.id, childId: child, occurredAt: occurred,
                                  body: body, updatedAt: newest, deletedAt: newest))
            previews.append(body)
        }
        try context.save()

        let body = syncJSON(entries: rows, cursor: laggedCursor(newest: newest))
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)

        #expect(plan.deletions.count == 12)
        let report = plan.report()
        for preview in previews {
            #expect(report.contains(preview), "every deletion is named, never summarised")
        }
        #expect(report.contains("WOULD BE SOFT-DELETED — 12 records"))
        #expect(report.contains("the row stays in the local store with deleted_at set"))
        // Newest first, so the most recent loss is the first thing read.
        #expect(plan.deletions.first?.occurredAt ?? .distantPast
            >= plan.deletions.last?.occurredAt ?? .distantFuture)
    }

    @Test("the report names every conflict and which side won")
    func reportNamesConflicts() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try cachedEntry(childId: child, occurredAt: occurred, body: "mine",
                                    updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(local)
        local.body = "edited here, not pushed"
        local.sync = .pending
        try context.save()

        let body = syncJSON(
            entries: [entryJSON(id: local.id, childId: child, occurredAt: occurred,
                                body: "theirs", updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)
        let report = plan.report()

        #expect(report.contains("CONFLICTS RESOLVED — 1"))
        #expect(report.contains("local won"))
        #expect(report.contains("the push queue wins"))
    }

    @Test("the report states the position, the round count, and the overlap window's footprint")
    func reportStatesPositionAndOverlap() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore(pullEnabled: true)
        state.setCursor(Date(timeIntervalSince1970: 1_650_000_000), for: child)

        let body = syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest, updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let plan = try #require(await engine(childId: child, performer: performer, context: context, state: state)
            .dryRun().plan)
        let report = plan.report()

        #expect(report.contains("POSITION"))
        #expect(report.contains("THE OVERLAP WINDOW (30s)"))
        #expect(report.contains("rounds    2"))
        #expect(plan.cursorBefore == Date(timeIntervalSince1970: 1_650_000_000))
        #expect(plan.cursorAfter == laggedCursor(newest: newest))
        #expect(plan.reDeliveredAcrossRounds == 1, "the same record arrived in both rounds")
    }

    /// The report is the only place the first real pull's cost is visible, and the cost of the
    /// apply — which runs on the main actor — is the open question this whole branch ships
    /// switched off in order to answer. A report that could not state it would be asking the
    /// parent to judge performance from a record that omits it.
    @Test("the report times the network and the apply separately")
    func reportStatesItsOwnCost() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let body = syncJSON(
            entries: (0..<20).map { index in
                entryJSON(
                    id: UUID(), childId: child,
                    occurredAt: newest.addingTimeInterval(Double(index)),
                    body: "entry \(index)", updatedAt: newest
                )
            },
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }

        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)
        let report = plan.report()

        #expect(report.contains("TIME"))
        #expect(report.contains("waiting on /sync"))
        // A dry run plans and does not write, and the report has to say which of the two it
        // measured rather than letting the number be read as the cost of a real apply.
        #expect(report.contains("planning"))
        #expect(report.contains("planning only — an apply writes as well"))
        #expect(!report.contains("on the main actor"), "that label belongs to a real apply")

        // Monotonic, so never negative however the wall clock moves underneath it.
        #expect(plan.networkSeconds >= 0)
        #expect(plan.applySeconds >= 0)
    }

    @Test("an applied pull labels the apply as main-actor work rather than planning")
    func appliedReportNamesTheApply() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let state = InMemorySyncStateStore(pullEnabled: true)

        let body = syncJSON(
            entries: [entryJSON(id: UUID(), childId: child, occurredAt: newest, updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }

        let plan = try #require(await engine(childId: child, performer: performer, context: context, state: state)
            .pull().plan)
        let report = plan.report()

        #expect(report.contains("SYNC PULL — applied"))
        #expect(report.contains("on the main actor"))
        #expect(!report.contains("planning only — an apply writes as well"))
    }

    @Test("a report with nothing to say says so plainly")
    func emptyReportIsHonest() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/sync") { _ in (syncJSON(cursor: Date(timeIntervalSince1970: 1_700_000_000)), 200) }

        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)
        let report = plan.report()

        #expect(report.contains("SYNC DRY RUN — nothing was written"))
        #expect(report.contains("nothing — the server had no records this device has not already applied"))
        #expect(report.contains("none — every record was understood"))
        #expect(plan.isNoOp)
    }

    @Test("anomalies are counted and named rather than folded into a total")
    func reportSurfacesAnomaliesLoudly() async throws {
        let context = try makeContext()
        let child = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let orphanEntry = UUID()

        let body = syncJSON(
            media: [syncMediaJSON(entryId: orphanEntry), syncMediaJSON(entryId: orphanEntry)],
            tags: [syncTagJSON(entryId: orphanEntry, name: "orphaned")],
            cursor: laggedCursor(newest: newest),
            extraKeys: ["milestones": "[]"]
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)
        let report = plan.report()

        #expect(report.contains("ANOMALIES — 4. Read these."))
        #expect(report.contains("media whose entry is unknown — 2"))
        #expect(report.contains("a tag on an unknown entry"))
        #expect(report.contains("unknown key in the response"))
        #expect(report.contains("milestones"))
    }

    @Test("the counts table breaks each entity down by action")
    func reportBreaksDownByEntityAndAction() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let stale = try cachedEntry(childId: child, occurredAt: occurred, body: "old",
                                    updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(stale)
        try context.save()

        let body = syncJSON(
            entries: [
                entryJSON(id: stale.id, childId: child, occurredAt: occurred, body: "new", updatedAt: newest),
                entryJSON(id: UUID(), childId: child, occurredAt: occurred, body: "fresh", updatedAt: newest),
            ],
            assignments: [syncAssignmentJSON(childId: child, updatedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)
        let report = plan.report()

        #expect(report.contains("insert  update  delete   skip  same"))
        #expect(plan.count(.entry, .insert) == 1)
        #expect(plan.count(.entry, .update) == 1)
        #expect(plan.count(.assignment, .insert) == 1)
        #expect(report.contains("3 writes in total"))
        // Media had nothing to say, so it is absent rather than shown as five zeroes.
        #expect(report.contains("medias") == false)
    }

    @Test("a body with newlines in it does not break the deletion list")
    func previewsAreSingleLine() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        let messy = try cachedEntry(childId: child, occurredAt: occurred,
                                    body: "first line", updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(messy)
        // Written straight onto the row: the point is the preview, not the wire format.
        messy.body = "first line\n\nsecond line   with    gaps"
        messy.sync = .synced
        try context.save()

        let body = syncJSON(
            entries: [entryJSON(id: messy.id, childId: child, occurredAt: occurred,
                                body: "first line", updatedAt: newest, deletedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)

        let preview = try #require(plan.deletions.first?.preview)
        #expect(preview.contains("\n") == false)
        #expect(preview == "first line")
    }

    @Test("a long body is elided rather than allowed to run away with the line")
    func longPreviewsAreElided() {
        let long = String(repeating: "a very long sentence ", count: 20)
        let preview = long.previewLine()
        #expect(preview.count <= 61)
        #expect(preview.hasSuffix("…"))
    }

    @Test("an entry with no title and no body still reads as an entry")
    func didItEntriesHaveAPreview() async throws {
        let context = try makeContext()
        let child = UUID()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)

        // "Get on the floor for ten minutes" is a complete, legitimate entry with no artifact
        // and no words. It must read as an entry, not as an empty row.
        let didIt = try cachedEntry(childId: child, occurredAt: occurred, type: "did_it", body: nil,
                                    updatedAt: Date(timeIntervalSince1970: 1_650_000_000))
        context.insert(didIt)
        try context.save()

        let body = syncJSON(
            entries: [entryJSON(id: didIt.id, childId: child, occurredAt: occurred, type: "did_it",
                                body: nil, updatedAt: newest, deletedAt: newest)],
            cursor: laggedCursor(newest: newest)
        )
        let performer = StubPerformer()
        performer.on("/sync") { _ in (body, 200) }
        let plan = try #require(await engine(childId: child, performer: performer, context: context).dryRun().plan)

        #expect(plan.deletions.first?.preview == "(no title or body)")
    }
}
