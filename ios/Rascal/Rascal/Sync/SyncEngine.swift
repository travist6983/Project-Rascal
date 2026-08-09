import Foundation
import OSLog
import SwiftData

/// The client's half of sync: `GET /v1/sync` since a cursor, folded into the local cache.
///
/// **The server is the source of truth and SwiftData is a cache** — with exactly one exception,
/// stated here because it is the difference between a sync engine and a data-loss bug: a local
/// record with unpushed changes is newer than anything the server can say about it, so the pull
/// leaves it alone and the push queue wins. It reconciles on the next pull after a successful
/// push.
///
/// Three defects close when this runs, all of them documented in `docs/roadmap-status.md`:
/// an entry deleted on another device never disappeared here, because `GET /entries` is paginated
/// and absence from a page cannot be read as a deletion; `POST /children/{id}/recompute-ages`
/// fixed the whole archive server-side while the client only re-read the newest page; and media
/// deletion worked only because every entry response carries its complete live media list, a
/// trick that does not generalise to entries.
///
/// ## The overlap window
///
/// The cursor the server hands back is **deliberately lagged**. From `api/src/rascal/services/
/// sync.py`:
///
/// > `set_updated_at()` uses `now()`, which is transaction-*start* time, so a row can commit with
/// > an `updated_at` already behind a cursor another device advanced past — and then never sync
/// > again. The cursor is handed back lagged by this much, so any row written by a transaction
/// > shorter than the window is re-delivered rather than lost. Clients upsert by id, and
/// > re-delivery is free: entries are last-write-wins on a client-generated UUID.
///
/// The consequence for this file is not "duplicates are tolerable". It is that **every apply path
/// here must be idempotent by construction**: applying the same record twice has to leave the
/// store byte-identical, because the window guarantees it will happen on every single pull. That
/// is why every `apply` is a pure assignment of server fields and never an accumulation.
///
/// ## Paging
///
/// `GET /sync` does not page. `api/src/rascal/routers/sync.py` declares one query parameter
/// besides `child_id` — there is no `limit` and no page token, and `service.pull` selects every
/// matching row for all four entities in one go. The loop here exists for a different reason: the
/// cursor comes back lagged, so one more call is what closes the gap between the lagged position
/// and the present. In practice that is two rounds against a live archive and one against an
/// idle one.
@MainActor
final class SyncEngine {

    /// Must match `CURSOR_OVERLAP_SECONDS` in `api/src/rascal/services/sync.py`.
    ///
    /// Held as a constant here so the report can state it, not to compute anything: the client
    /// never applies the lag itself. The server owns the cursor and the client feeds it back
    /// verbatim. A client that subtracted its own window would double the overlap and, worse,
    /// would be quietly wrong the day the server's constant changes.
    nonisolated static let overlapWindow: TimeInterval = 30

    /// A hard stop on the round loop.
    ///
    /// Two rounds is the expected number and eight is far outside it, so reaching this means an
    /// assumption is wrong rather than that the archive is large. It is a backstop against a
    /// server whose cursor advances forever, which would otherwise be an unbounded request loop
    /// on a parent's cellular data.
    nonisolated static let maxRounds = 8

    /// Records applied between yields to the main run loop. See `yieldIfNeeded`.
    nonisolated static let yieldEvery = 100

    private static let log = Logger(subsystem: "app.rascal", category: "sync")

    private let childId: UUID
    private let api: APIClient
    private let context: ModelContext
    private let state: SyncStateStoring
    /// The push queue. **Drained before every pull** — pulling first can hand back a stale server
    /// row that overwrites a local edit which has not been pushed yet. Same discipline as
    /// entries-before-media in the upload sweep.
    private let push: EntrySync?
    private let hooks: Hooks

    /// A narrow, deliberately ugly seam so the rollback contract can be asserted rather than
    /// reasoned about. Nil in every shipped path. Precedent: `APIClient.refreshCount`.
    nonisolated struct Hooks: Sendable {
        /// Called with the round number immediately before that round is saved. Throwing from it
        /// exercises a mid-apply failure, which is otherwise unreachable from a test.
        var beforeSave: (@Sendable (Int) throws -> Void)?

        init(beforeSave: (@Sendable (Int) throws -> Void)? = nil) {
            self.beforeSave = beforeSave
        }
    }

    /// The one in-flight operation, and what kind it is.
    ///
    /// Claimed synchronously, for the reason spelled out at length in `APIClient.refreshSession`:
    /// an `async` function may suspend between statements that contain no visible `await`, so a
    /// check-then-assign written across a suspension point is not atomic however atomic it reads.
    private var inFlight: (mode: Mode, task: Task<SyncOutcome, Never>)?

    private enum Mode: Equatable { case apply, dryRun }

    init(
        childId: UUID,
        api: APIClient,
        context: ModelContext,
        state: SyncStateStoring,
        push: EntrySync? = nil,
        hooks: Hooks = Hooks()
    ) {
        self.childId = childId
        self.api = api
        self.context = context
        self.state = state
        self.push = push
        self.hooks = hooks
    }

    // MARK: - What Settings reads

    var pullEnabled: Bool {
        get { state.pullEnabled }
        set { state.pullEnabled = newValue }
    }

    var cursor: Date? { state.cursor(for: childId) }
    var lastSuccess: Date? { state.lastSuccess(for: childId) }
    var lastError: String? { state.lastError(for: childId) }

    /// Forget the position, so the next pull reads the whole archive.
    ///
    /// The recovery path, and the same branch a cursor that cannot be parsed already takes. It is
    /// safe by construction rather than by care: a full pull is the cold-start path, which is
    /// tested, and every apply is idempotent, so re-reading records already held changes nothing.
    func resetCursor() {
        state.setCursor(nil, for: childId)
        Self.log.notice("sync cursor reset for child \(self.childId, privacy: .public)")
    }

    // MARK: - Triggers

    /// Drain the push queue, then apply everything the server has.
    ///
    /// **Gated on `pullEnabled`, which ships false.** With the flag off this drains the push
    /// queue exactly as before and returns without reading `/sync` or touching the cache.
    ///
    /// Silent on failure by design: a routine failed sync is a fact about the network, and
    /// nothing on Today or Timeline scolds or spins about it. The Settings sync-status section is
    /// where it surfaces.
    @discardableResult
    func pull() async -> SyncOutcome {
        // Before the flag, not after. Push is the existing, verified path and it must keep
        // running whether or not the new half is switched on.
        await push?.sweep()

        guard state.pullEnabled else { return .disabled }
        return await run(mode: .apply)
    }

    /// What a pull would do, without doing any of it.
    ///
    /// Works regardless of the flag — that is the whole point of it. Performs a genuine
    /// `GET /sync` against the real cursor and applies nothing.
    func dryRun() async -> SyncOutcome {
        await run(mode: .dryRun)
    }

    // MARK: - Coalescing

    private enum Claim {
        /// An identical operation is already running. Its result is this caller's result.
        case joined(Task<SyncOutcome, Never>)
        /// A different operation is running. Wait for it, then try again.
        case blocked(Task<SyncOutcome, Never>)
        case owner(Task<SyncOutcome, Never>)
    }

    private func run(mode: Mode) async -> SyncOutcome {
        while true {
            switch claim(mode) {
            case .joined(let task):
                // Four triggers firing at once is one pull, not four. The second caller gets the
                // first caller's answer rather than starting a duplicate request.
                return await task.value
            case .blocked(let task):
                _ = await task.value
                continue
            case .owner(let task):
                let outcome = await task.value
                inFlight = nil
                return outcome
            }
        }
    }

    /// Synchronous on purpose. See `inFlight`.
    private func claim(_ mode: Mode) -> Claim {
        if let existing = inFlight {
            return existing.mode == mode ? .joined(existing.task) : .blocked(existing.task)
        }
        let task = Task<SyncOutcome, Never> { [weak self] in
            guard let self else { return .disabled }
            return await self.execute(mode: mode)
        }
        inFlight = (mode, task)
        return .owner(task)
    }

    // MARK: - The run

    private func execute(mode: Mode) async -> SyncOutcome {
        let applying = mode == .apply
        var plan = SyncPlan(cursorBefore: state.cursor(for: childId), isDryRun: !applying)
        // Where each record already sits in `plan.changes`. The overlap window guarantees round
        // two re-delivers part of round one, and counting one record twice would make the report
        // lie about volume — so the later decision replaces the earlier one in place.
        var changeIndex: [String: Int] = [:]
        var since = plan.cursorBefore

        for round in 1...Self.maxRounds {
            let response: SyncPullResponse
            // Timed separately from the apply below. Network cost and main-actor cost are
            // different problems with different fixes, and a single total would hide which one a
            // slow pull actually was. Both accumulate across rounds, and a round that fails still
            // reports the time it spent before failing.
            let networkStarted = ContinuousClock.now
            do {
                response = try await api.syncPull(childId: childId, since: since)
                plan.networkSeconds += Self.elapsed(since: networkStarted)
            } catch {
                plan.networkSeconds += Self.elapsed(since: networkStarted)
                // The cursor is untouched, so the records this round would have carried are still
                // ahead of it and arrive on the next attempt. Nothing is lost by stopping here.
                let message = Self.describe(error)
                if applying { state.recordError(message, for: childId) }
                Self.log.notice("sync pull failed at round \(round): \(message, privacy: .public)")
                plan.collapseRepeats()
                return .failed(SyncFailure(message: message, plan: plan))
            }

            plan.rounds = round
            plan.fetched += response.recordCount
            for key in response.unrecognisedKeys {
                plan.anomalies.append(SyncAnomaly(
                    kind: .unknownResponseKey,
                    detail: "`\(key)` — the server sent it, this client has no model for it"
                ))
            }

            let applyStarted = ContinuousClock.now
            do {
                try await applyRound(response, round: round, into: &plan, index: &changeIndex, applying: applying)
                plan.applySeconds += Self.elapsed(since: applyStarted)
            } catch {
                plan.applySeconds += Self.elapsed(since: applyStarted)
                // **Never advance past records that failed to apply.** The round's changes are
                // discarded and the cursor stays where the last clean round left it; a partial
                // advance would lose those records permanently and silently.
                context.rollback()
                let message = Self.describe(error)
                if applying { state.recordError(message, for: childId) }
                Self.log.error("sync apply failed at round \(round), cursor left at prior position: \(message, privacy: .public)")
                plan.collapseRepeats()
                return .failed(SyncFailure(message: message, plan: plan))
            }

            plan.cursorAfter = response.cursor
            if applying { state.setCursor(response.cursor, for: childId) }

            // Termination, and the order of these two checks matters.
            //
            // **Empty first.** On an empty batch the server has no rows to take a maximum from,
            // so it returns `now() - 30s` — which is *ahead* of whatever was sent. Testing only
            // for cursor movement would spin forever against an idle archive, each round
            // advancing by a little wall-clock and fetching nothing.
            if response.isEmpty { break }
            // Then movement. With rows present the cursor is `max(updated_at) - 30s`, so the
            // second round re-reads the lag band, finds the same maximum, and returns the same
            // cursor. That is the normal two-round finish.
            if let previous = since, response.cursor <= previous { break }
            since = response.cursor

            if round == Self.maxRounds {
                let detail = "stopped after \(Self.maxRounds) rounds with the cursor still moving"
                plan.anomalies.append(SyncAnomaly(kind: .pagingCapReached, detail: detail))
                Self.log.warning("sync \(detail, privacy: .public)")
            }
        }

        plan.collapseRepeats()
        if applying {
            state.recordSuccess(Date(), for: childId)
            Self.log.notice("sync applied \(plan.writeCount) write(s) over \(plan.rounds) round(s)")
        }
        return .completed(plan)
    }

    /// Plan one response, and apply it when asked to.
    ///
    /// Planning and applying share this one pass on purpose. A dry run that ran different code
    /// from the real thing would be a report about a program nobody is going to run.
    ///
    /// **Entries before media, always.** Mirrors the upload sweep's ordering for the same reason
    /// in reverse: a media row whose entry has not been applied yet has nothing to belong to.
    /// Applying entries first by construction means the held-and-apply-later case never arises
    /// within a batch; a media row whose entry is not in the batch *and* not already on this
    /// device is still applied, and reported as an anomaly rather than dropped.
    private func applyRound(
        _ response: SyncPullResponse,
        round: Int,
        into plan: inout SyncPlan,
        index: inout [String: Int],
        applying: Bool
    ) async throws {
        var applied = 0

        func note(_ change: PlannedChange) {
            if let existing = index[change.dedupeKey] {
                plan.reDeliveredAcrossRounds += 1
                // Already decided in an earlier round of this run. The **more significant**
                // verdict survives, not the later one: by round two a record round one inserted
                // is genuinely unchanged, because round two is looking at round one's own work.
                // Reporting that as "unchanged" would hide the write that actually happened.
                if change.action.significance > plan.changes[existing].action.significance {
                    plan.changes[existing] = change
                }
                return
            }
            index[change.dedupeKey] = plan.changes.count
            plan.changes.append(change)
        }

        // Duplicate ids inside one response are not something the server should ever produce, and
        // that is exactly why they are worth naming rather than quietly letting the last one win.
        detectDuplicates(response, into: &plan)

        // Media that is live *before* this round's entries are applied.
        //
        // Load bearing for the report, not for the apply. An entry's inline media list is
        // live-only, so applying the entry marks any photo missing from it as deleted — which is
        // the existing, correct path. By the time `planMedia` reaches the same row through the
        // top-level array, it is already deleted, and the honest verdict for a deletion this
        // round performed is `soft-delete`, not `unchanged`. Without this snapshot the applied
        // plan under-reports media deletions relative to the dry run that predicted them.
        let liveMediaBefore = Set(
            ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
                .filter { $0.deletedAt == nil }
                .map(\.id)
        )

        for incoming in response.entries {
            note(planEntry(incoming, applying: applying, into: &plan))
            applied += 1
            await yieldIfNeeded(applied)
        }

        for incoming in response.media {
            note(planMedia(incoming, liveBefore: liveMediaBefore, applying: applying, into: &plan))
            applied += 1
            await yieldIfNeeded(applied)
        }

        for incoming in response.assignments {
            note(planAssignment(incoming, applying: applying, into: &plan))
            applied += 1
            await yieldIfNeeded(applied)
        }

        for incoming in response.tags {
            note(planTag(incoming, applying: applying, into: &plan))
            applied += 1
            await yieldIfNeeded(applied)
        }

        guard applying else {
            // **Nothing was written, so nothing is saved.** The context is left exactly as it was
            // found; the store is byte-identical before and after a dry run.
            return
        }
        try hooks.beforeSave?(round)
        try context.save()
    }

    /// Hand the main run loop a turn every so often.
    ///
    /// The apply runs on the main actor because that is where the `ModelContext` the app's views
    /// read from lives. Seven hundred records applied without a break would hold the actor for
    /// the whole batch and drop frames; yielding lets the UI service a touch between chunks.
    /// This is cooperative — it does not move the work off the main thread, it stops the work
    /// monopolising it.
    private func yieldIfNeeded(_ applied: Int) async {
        if applied % Self.yieldEvery == 0 { await Task.yield() }
    }

    private func detectDuplicates(_ response: SyncPullResponse, into plan: inout SyncPlan) {
        func check<T>(_ items: [T], _ entity: SyncEntity, _ id: (T) -> UUID) {
            var seen = Set<UUID>()
            for item in items where !seen.insert(id(item)).inserted {
                plan.anomalies.append(SyncAnomaly(
                    kind: .duplicateIdInBatch,
                    detail: "\(entity.rawValue) \(id(item).uuidString) appeared twice in one batch"
                ))
            }
        }
        check(response.entries, .entry) { $0.id }
        check(response.media, .media) { $0.id }
        check(response.assignments, .assignment) { $0.id }
        // A tag link is identified by the pair, not by either half — one entry legitimately
        // carries many links and one tag legitimately appears on many entries.
        var seenLinks = Set<String>()
        for link in response.tags {
            let key = "\(link.entryId.uuidString):\(link.tagId.uuidString)"
            if !seenLinks.insert(key).inserted {
                plan.anomalies.append(SyncAnomaly(
                    kind: .duplicateIdInBatch,
                    detail: "tag `\(link.name)` on entry \(link.entryId.uuidString) appeared twice in one batch"
                ))
            }
        }
    }

    // MARK: - Entries

    /// Identity is the client-generated entry id, so a row created in the composer and the same
    /// row coming back from `/sync` are one row and never two.
    private func planEntry(
        _ incoming: EntryResponse,
        applying: Bool,
        into plan: inout SyncPlan
    ) -> PlannedChange {
        let preview = Self.preview(title: incoming.title, body: incoming.body)

        guard let existing = EntryCache.entry(id: incoming.id, in: context) else {
            if applying {
                let entry = Entry(
                    id: incoming.id,
                    childId: incoming.childId,
                    assignmentId: incoming.assignmentId,
                    occurredAt: incoming.occurredAt,
                    createdAt: incoming.createdAt,
                    title: incoming.title,
                    body: incoming.body,
                    unlockAtAge: incoming.unlockAtAge
                )
                entry.applyServerTruth(incoming)
                context.insert(entry)
                // An entry's inline media list is live-only, so it can add and reconcile rows but
                // can never carry a deletion. The top-level `media` array is what deletes.
                EntryCache.upsertMedia(incoming.media, entryId: incoming.id, into: context)
            }
            return PlannedChange(
                entity: .entry, recordId: incoming.id, action: .insert,
                preview: preview, occurredAt: incoming.occurredAt
            )
        }

        // **The one exception to server-is-truth.** A row this phone has written and not yet
        // pushed is the parent's most recent intent, and it is newer than anything the server can
        // say about it. Overwriting it would mean an edit made on a train disappears the moment
        // the train reaches a signal.
        if Self.hasUnpushedChanges(existing) {
            plan.conflicts.append(SyncConflict(
                entity: .entry, recordId: incoming.id, winner: .local, preview: preview,
                reason: existing.deletionPending
                    ? "deleted here and not yet pushed; the pull leaves it alone"
                    : "written here and not yet pushed (\(existing.sync.rawValue)); the push queue wins"
            ))
            return PlannedChange(
                entity: .entry, recordId: incoming.id, action: .skippedLocalPending,
                preview: preview, occurredAt: existing.occurredAt
            )
        }

        // A deletion only ever goes one way, here and in `Entry.applyServerResponse`. There is no
        // undelete anywhere in this system.
        if incoming.deletedAt != nil {
            guard existing.deletedAt == nil else {
                return PlannedChange(
                    entity: .entry, recordId: incoming.id, action: .unchanged,
                    preview: preview, occurredAt: existing.occurredAt
                )
            }
            if applying {
                existing.applyServerTruth(incoming)
                // The media has to carry its own `deleted_at`, exactly as the server does it —
                // a client that keeps the media row alive keeps rendering the photo.
                for row in EntryCache.media(ofEntry: incoming.id, in: context) where row.deletedAt == nil {
                    row.deletedAt = incoming.deletedAt
                }
            }
            return PlannedChange(
                entity: .entry, recordId: incoming.id, action: .softDelete,
                preview: preview, occurredAt: existing.occurredAt
            )
        }

        // Last-write-wins by `updated_at`, matching the server. A synced row always carries the
        // server's own timestamp — `applyServerResponse` writes it — so this comparison is
        // between two server values rather than against a local clock.
        guard incoming.updatedAt > existing.updatedAt else {
            if applying {
                // The inline list still reconciles: a photo deleted on another phone is absent
                // from it, and that absence is information on this one path.
                EntryCache.upsertMedia(incoming.media, entryId: incoming.id, into: context)
            }
            return PlannedChange(
                entity: .entry, recordId: incoming.id, action: .unchanged,
                preview: preview, occurredAt: existing.occurredAt
            )
        }

        if applying {
            existing.applyServerTruth(incoming)
            EntryCache.upsertMedia(incoming.media, entryId: incoming.id, into: context)
        }
        return PlannedChange(
            entity: .entry, recordId: incoming.id, action: .update,
            preview: preview, occurredAt: incoming.occurredAt
        )
    }

    /// Work this phone has done that the server has not acknowledged.
    ///
    /// `failed` counts as pending: a failure is a network fact, not a verdict about the entry,
    /// and the row is still carrying an edit nobody else has. Same reasoning as
    /// `EntrySync.unsyncedDescriptor`, which retries `failed` alongside `pending`.
    private static func hasUnpushedChanges(_ entry: Entry) -> Bool {
        entry.sync != .synced || entry.deletionPending || !entry.existsOnServer
    }

    // MARK: - Media

    private func planMedia(
        _ incoming: SyncMediaResponse,
        liveBefore: Set<UUID>,
        applying: Bool,
        into plan: inout SyncPlan
    ) -> PlannedChange {
        let preview = "\(incoming.kind) · \(ByteCountFormatter.string(fromByteCount: Int64(incoming.bytes), countStyle: .file))"

        // Entries were applied first, so an entry in this batch is already on the device. One
        // that is still unknown belongs to an entry this device has never held.
        if EntryCache.entry(id: incoming.entryId, in: context) == nil {
            plan.anomalies.append(SyncAnomaly(
                kind: .mediaWithoutEntry,
                detail: "media \(incoming.id.uuidString) belongs to entry \(incoming.entryId.uuidString), which is not in this batch and not on this device — applied anyway, not dropped"
            ))
        }

        guard let existing = EntryCache.media(id: incoming.id, in: context) else {
            // A row the server still calls pending has no bytes anywhere this device can reach,
            // and creating it locally would enrol it in the upload sweep — which would hunt for a
            // staged file that was never here and mark somebody else's healthy upload as failed.
            guard incoming.isComplete, incoming.deletedAt == nil else {
                return PlannedChange(
                    entity: .media, recordId: incoming.id, action: .unchanged,
                    preview: "\(preview) (\(incoming.uploadStatus), not cached)", occurredAt: nil
                )
            }
            if applying, let created = Media.fromServer(incoming.asSummary, entryId: incoming.entryId) {
                created.createdAt = incoming.createdAt
                created.updatedAt = incoming.updatedAt
                context.insert(created)
            }
            return PlannedChange(
                entity: .media, recordId: incoming.id, action: .insert,
                preview: preview, occurredAt: incoming.capturedAt
            )
        }

        // Bytes this phone is still carrying, or words it has written and not yet delivered.
        // The server's row describes a journey that has not finished, and folding it over local
        // state would drag a row mid-flight backwards.
        if Self.hasUnpushedChanges(existing) {
            plan.conflicts.append(SyncConflict(
                entity: .media, recordId: incoming.id, winner: .local, preview: preview,
                reason: existing.hasUnpushedTranscript
                    ? "transcribed here and not yet pushed (\(existing.transcriptSync.rawValue)); the transcription queue wins"
                    : "this file is still uploading from here (\(existing.state.rawValue)); the upload sweep wins"
            ))
            return PlannedChange(
                entity: .media, recordId: incoming.id, action: .skippedLocalPending,
                preview: preview, occurredAt: existing.capturedAt
            )
        }

        if incoming.deletedAt != nil {
            // `liveBefore`, not `existing.deletedAt`: this round's entry application may already
            // have marked the row through the inline list, and a deletion this round performed
            // is a soft-delete however it got there. See where the snapshot is taken.
            guard liveBefore.contains(incoming.id) else {
                return PlannedChange(
                    entity: .media, recordId: incoming.id, action: .unchanged,
                    preview: preview, occurredAt: existing.capturedAt
                )
            }
            // Assigned unconditionally so the row ends up carrying the *server's* timestamp. The
            // inline path stamps a local `now`, which is a guess at when someone else deleted it.
            if applying { existing.deletedAt = incoming.deletedAt }
            return PlannedChange(
                entity: .media, recordId: incoming.id, action: .softDelete,
                preview: preview, occurredAt: existing.capturedAt
            )
        }

        // **`MediaOut` carries `updated_at`, but a local media row's `updatedAt` is written by
        // this device's own clock** — `Media.state` stamps it on every transition. Comparing the
        // two would be comparing a server timestamp against a local one. So "has anything
        // actually changed" is answered by looking at the fields themselves.
        guard Self.differs(existing, from: incoming) else {
            return PlannedChange(
                entity: .media, recordId: incoming.id, action: .unchanged,
                preview: preview, occurredAt: existing.capturedAt
            )
        }
        if applying {
            existing.applyServerSummary(incoming.asSummary)
            existing.updatedAt = incoming.updatedAt
        }
        return PlannedChange(
            entity: .media, recordId: incoming.id, action: .update,
            preview: preview, occurredAt: incoming.capturedAt
        )
    }

    /// Whether the fields `applyServerSummary` writes would come out different.
    ///
    /// Mirrors that method exactly, including its three one-way rules: a list row must not blank a
    /// transcript the detail fetch cached, a transcript written here and not yet pushed is not
    /// written at all, and upload state is only ever moved forward to `complete`. A predicate that
    /// disagreed with the writer would make the report claim updates that do nothing, or miss ones
    /// that do something.
    ///
    /// The transcript clause is unreachable in practice — `hasUnpushedChanges` short-circuits such
    /// a row into `skippedLocalPending` before this is asked — and it is written anyway, because
    /// "mirrors that method exactly" has to survive the next person who changes one of them.
    private static func differs(_ existing: Media, from incoming: SyncMediaResponse) -> Bool {
        if existing.s3Key != incoming.s3Key { return true }
        if existing.thumbKey != incoming.thumbKey { return true }
        if let duration = incoming.durationSeconds, existing.durationSeconds != duration { return true }
        if let captured = incoming.capturedAt, existing.capturedAt != captured { return true }
        if !existing.hasUnpushedTranscript,
           let transcript = incoming.transcript, existing.transcript != transcript { return true }
        if let caption = incoming.caption, existing.caption != caption { return true }
        if incoming.isComplete, !existing.isComplete { return true }
        if existing.updatedAt != incoming.updatedAt { return true }
        return false
    }

    /// A media row this phone is still working on — in either of the two senses.
    ///
    /// **The bytes.** `staged`, `uploading`, `uploaded` are in flight. `failed` deliberately is
    /// not: past the retry cap there is nothing in flight to protect, and the server's copy is the
    /// better of the two.
    ///
    /// **The words.** A transcript written here and not pushed is a pending local change on a row
    /// whose upload finished long ago — `complete`, and therefore invisible to the switch below.
    /// Without the first clause a pull carrying the server's older row would take the
    /// `.update` branch and `applyServerSummary` would overwrite words that exist nowhere else.
    /// This is the case `SyncEngineTests` calls out by name.
    ///
    /// Note the asymmetry with the bytes: `failed` **does** count here, and
    /// `Media.hasUnpushedTranscript` says why.
    private static func hasUnpushedChanges(_ media: Media) -> Bool {
        if media.hasUnpushedTranscript { return true }
        switch media.state {
        case .staged, .uploading, .uploaded: return true
        default: return false
        }
    }

    // MARK: - Assignments

    private func planAssignment(
        _ incoming: SyncAssignmentResponse,
        applying: Bool,
        into plan: inout SyncPlan
    ) -> PlannedChange {
        let preview = incoming.body.previewLine()

        if case .unknown(let raw) = incoming.status {
            plan.anomalies.append(SyncAnomaly(
                kind: .unrecognisedValue,
                detail: "assignment \(incoming.id.uuidString) has status `\(raw)`, which this client has no case for"
            ))
        }

        // **A pull must never revert a locally-completed mission back to pending.** This is the
        // standing rule Today already follows in `TodayBoard.merge`, enforced here as well so the
        // cache agrees with the screen rather than relying on the screen to paper over it. The
        // server has not heard about the completion yet; when it has, the next pull carries
        // `done` and this branch stops firing.
        let completedLocally = locallyCompleted(assignmentId: incoming.id)
        if completedLocally, incoming.status != .done {
            plan.conflicts.append(SyncConflict(
                entity: .assignment, recordId: incoming.id, winner: .local, preview: preview,
                reason: "completed on this phone and not yet pushed; the server still says `\(incoming.status.rawValue)`"
            ))
            return PlannedChange(
                entity: .assignment, recordId: incoming.id, action: .skippedLocalPending,
                preview: preview, occurredAt: nil
            )
        }

        guard let existing = Self.assignment(id: incoming.id, in: context) else {
            if applying { context.insert(Assignment.fromServer(incoming)) }
            return PlannedChange(
                entity: .assignment, recordId: incoming.id, action: .insert,
                preview: preview, occurredAt: nil
            )
        }

        // Assignments carry no `deleted_at` — the server changes `status` instead — so there is
        // no soft-delete branch here, and its absence is a fact about the contract rather than a
        // gap in this file.
        guard existing.differs(from: incoming) else {
            return PlannedChange(
                entity: .assignment, recordId: incoming.id, action: .unchanged,
                preview: preview, occurredAt: nil
            )
        }
        if applying { existing.apply(incoming) }
        return PlannedChange(
            entity: .assignment, recordId: incoming.id, action: .update,
            preview: preview, occurredAt: nil
        )
    }

    /// Is there a live local entry completing this assignment?
    ///
    /// The same question `TodayBoard.merge` asks to decide whether a card is done, asked against
    /// the cache instead of against a rendered board.
    private func locallyCompleted(assignmentId: UUID) -> Bool {
        // Bound as an optional deliberately: `assignmentId` on `Entry` is `UUID?`, and mixing an
        // optional column with a non-optional capture inside `#Predicate` is exactly the kind of
        // thing the macro compiles into a comparison that never matches.
        let target: UUID? = assignmentId
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entry.assignmentId == target && entry.deletedAt == nil
            }
        )
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
    }

    static func assignment(id: UUID, in context: ModelContext) -> Assignment? {
        var descriptor = FetchDescriptor<Assignment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Tags

    /// Tag links fold onto `Entry.storedTagNames`.
    ///
    /// The client denormalises tag names onto the entry rather than modelling a `Tag` — see the
    /// note on that property. The link is still what the server sends, because a bare tag list
    /// would not say which entry lost which tag, so the fold is add-on-live, remove-on-deleted.
    private func planTag(
        _ incoming: SyncTagResponse,
        applying: Bool,
        into plan: inout SyncPlan
    ) -> PlannedChange {
        let preview = "\(incoming.name) on \(incoming.entryId.uuidString.prefix(8))"

        guard let entry = EntryCache.entry(id: incoming.entryId, in: context) else {
            plan.anomalies.append(SyncAnomaly(
                kind: .tagWithoutEntry,
                detail: "tag `\(incoming.name)` names entry \(incoming.entryId.uuidString), which is not in this batch and not on this device"
            ))
            return PlannedChange(
                entity: .tag, recordId: incoming.entryId, action: .unchanged,
                preview: "\(preview) (no such entry here)", occurredAt: nil,
                discriminator: incoming.name
            )
        }

        if Self.hasUnpushedChanges(entry) {
            plan.conflicts.append(SyncConflict(
                entity: .tag, recordId: incoming.entryId, winner: .local, preview: preview,
                reason: "its entry has unpushed changes; the push queue wins"
            ))
            return PlannedChange(
                entity: .tag, recordId: incoming.entryId, action: .skippedLocalPending,
                preview: preview, occurredAt: entry.occurredAt,
                discriminator: incoming.name
            )
        }

        var names = entry.tagNames
        let held = names.contains(incoming.name)

        if incoming.isRemoved {
            guard held else {
                return PlannedChange(
                    entity: .tag, recordId: incoming.entryId, action: .unchanged,
                    preview: preview, occurredAt: entry.occurredAt
                )
            }
            if applying {
                names.removeAll { $0 == incoming.name }
                entry.tagNames = names
            }
            return PlannedChange(
                entity: .tag, recordId: incoming.entryId, action: .softDelete,
                preview: preview, occurredAt: entry.occurredAt,
                discriminator: incoming.name
            )
        }

        guard !held else {
            return PlannedChange(
                entity: .tag, recordId: incoming.entryId, action: .unchanged,
                preview: preview, occurredAt: entry.occurredAt,
                discriminator: incoming.name
            )
        }
        if applying {
            names.append(incoming.name)
            entry.tagNames = names
        }
        return PlannedChange(
            entity: .tag, recordId: incoming.entryId, action: .insert,
            preview: preview, occurredAt: entry.occurredAt,
            discriminator: incoming.name
        )
    }

    // MARK: - Scaffolding

    private static func preview(title: String?, body: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title.previewLine()
        }
        if let body, !body.trimmingCharacters(in: .whitespaces).isEmpty {
            return body.previewLine()
        }
        // A complete, legitimate entry with no artifact and no words. "Get on the floor for ten
        // minutes" is one of these, and it must read as an entry rather than as an empty row.
        return "(no title or body)"
    }

    private static func describe(_ error: Error) -> String {
        (error as? APIError)?.userMessage ?? error.localizedDescription
    }

    /// Seconds since an instant, on the monotonic clock.
    ///
    /// `ContinuousClock` rather than `Date`: a wall clock can step sideways mid-pull — NTP, a
    /// timezone change, the parent editing the date — and a negative or wildly inflated duration
    /// in the report would be read as a performance problem that never happened.
    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let components = (ContinuousClock.now - start).components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

// MARK: - Outcomes

nonisolated enum SyncOutcome: Sendable {
    /// `syncPullEnabled` is off. Nothing was read and nothing was written.
    case disabled
    case completed(SyncPlan)
    case failed(SyncFailure)

    var plan: SyncPlan? {
        switch self {
        case .completed(let plan): plan
        case .failed(let failure): failure.plan
        case .disabled: nil
        }
    }

    var errorMessage: String? {
        if case .failed(let failure) = self { return failure.message }
        return nil
    }
}

nonisolated struct SyncFailure: Sendable {
    let message: String
    /// What had been planned before the failure. Partial by definition, and labelled as such in
    /// the report rather than presented as a complete picture.
    let plan: SyncPlan?
}
