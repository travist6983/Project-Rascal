import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The sync surface: one set of numbers, a reconciliation for rows the system forgot, and a retry
/// that either acts or says why it cannot.
@MainActor
private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: LocalStore.schema,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
}

private func makeStore() -> StagingStore {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "rascal-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    return StagingStore(root: root)
}

/// A media row in a given state, with or without bytes actually on disk.
@MainActor
private func seedMedia(
    in context: ModelContext,
    store: StagingStore,
    state: MediaUploadState,
    withBytes: Bool,
    attempts: Int = 0
) throws -> Media {
    let row = Media(
        entryId: UUID(),
        kind: "photo",
        contentType: "image/jpeg",
        byteCount: 1234,
        durationSeconds: nil
    )
    row.state = state
    row.attemptCount = attempts
    if withBytes {
        _ = try store.stage(data: Data("bytes".utf8), as: row.id, ext: "jpg")
        row.stagedExtension = "jpg"
    }
    context.insert(row)
    try context.save()
    return row
}

// MARK: - Rows the system forgot

/// **The stalled-`uploading` condition, and it is permanent rather than a race.** `dueMedia`
/// excludes `uploading` by *state*, not by the in-flight set — so an empty `inFlightMediaIds()`
/// does not rescue the row, and nothing else moves it: only the two `URLSessionTask` delegate
/// callbacks write a row out of `uploading`. iOS discards background tasks across a reboot or a
/// force quit, and `MediaUploader.finishPart` strands a parent row in `uploading` on any part
/// failure below the retry cap.
@MainActor
@Suite("Phase 81 — a row the system forgot gets picked back up")
struct StalledUploadReconciliationTests {

    @Test("an uploading row with no live task returns to staged")
    func strandedRowIsRecovered() throws {
        let context = try makeContext()
        let store = makeStore()
        let row = try seedMedia(in: context, store: store, state: .uploading, withBytes: true)

        let moved = MediaCoordinator.reconcileStalledUploads(in: context, inFlight: [])

        #expect(moved == 1)
        #expect(row.state == .staged, "staged means 'start over', which is what beginUpload does")
    }

    @Test("a row that really is in flight is left alone")
    func liveRowIsUntouched() throws {
        let context = try makeContext()
        let store = makeStore()
        let row = try seedMedia(in: context, store: store, state: .uploading, withBytes: true)

        let moved = MediaCoordinator.reconcileStalledUploads(in: context, inFlight: [row.id])

        #expect(moved == 0)
        #expect(row.state == .uploading, "cancelling a live upload to 'fix' it would lose progress")
    }

    @Test("the reconciliation does not reset anybody's backoff ladder")
    func attemptsSurvive() throws {
        // This is a reconciliation, not a manual retry. Zeroing attempts here would let a
        // genuinely failing row spin forever without ever reaching the cap.
        let context = try makeContext()
        let store = makeStore()
        let row = try seedMedia(
            in: context, store: store, state: .uploading, withBytes: true, attempts: 4
        )

        MediaCoordinator.reconcileStalledUploads(in: context, inFlight: [])

        #expect(row.attemptCount == 4)
    }

    @Test("states other than uploading are not touched")
    func onlyUploadingIsReconciled() throws {
        let context = try makeContext()
        let store = makeStore()
        let staged = try seedMedia(in: context, store: store, state: .staged, withBytes: true)
        let failed = try seedMedia(in: context, store: store, state: .failed, withBytes: true)
        let uploaded = try seedMedia(in: context, store: store, state: .uploaded, withBytes: true)

        #expect(MediaCoordinator.reconcileStalledUploads(in: context, inFlight: []) == 0)
        #expect(staged.state == .staged)
        #expect(failed.state == .failed, "a failed row is the retry's business, not this one's")
        #expect(uploaded.state == .uploaded)
    }
}

// MARK: - One set of numbers

@MainActor
@Suite("Phase 81 — the counts come from one read")
struct SyncCountsReadTests {

    @Test("waiting and stalled are counted separately from the same rows")
    func waitingAndStalledSplit() throws {
        let context = try makeContext()
        let store = makeStore()
        _ = try seedMedia(in: context, store: store, state: .staged, withBytes: true)
        _ = try seedMedia(in: context, store: store, state: .uploading, withBytes: true)
        _ = try seedMedia(in: context, store: store, state: .failed, withBytes: true)

        let counts = SyncCounts.read(context: context, store: store)

        #expect(counts.waitingMedia == 2)
        #expect(counts.stalledMedia == 1)
        #expect(counts.total == 3, "and the total is the sum, not a third independent number")
    }

    @Test("a complete row is not outstanding at all")
    func completeIsNotCounted() throws {
        let context = try makeContext()
        let store = makeStore()
        _ = try seedMedia(in: context, store: store, state: .complete, withBytes: true)

        #expect(SyncCounts.read(context: context, store: store).isClear)
    }

    /// A stalled row whose bytes are gone cannot be retried at all, and is a different thing from
    /// one that can. The same class of lie phase 80 fixed at the entry level.
    @Test("a stalled row with no bytes on disk is counted as unretryable")
    func missingBytesAreCounted() throws {
        let context = try makeContext()
        let store = makeStore()
        _ = try seedMedia(in: context, store: store, state: .failed, withBytes: true)
        _ = try seedMedia(in: context, store: store, state: .failed, withBytes: false)

        let counts = SyncCounts.read(context: context, store: store)

        #expect(counts.stalledMedia == 2)
        #expect(counts.stalledWithoutBytes == 1)
        #expect(counts.retryable == 1)
    }

    @Test("a soft-deleted row is not counted")
    func deletedIsNotCounted() throws {
        let context = try makeContext()
        let store = makeStore()
        let row = try seedMedia(in: context, store: store, state: .staged, withBytes: true)
        row.deletedAt = Date()
        try context.save()

        #expect(SyncCounts.read(context: context, store: store).isClear)
    }
}

// MARK: - A retry that acts

@MainActor
@Suite("Phase 81 — Retry now acts, and reports what happened")
struct RetryActsTests {

    @Test("it resets the ladder on stalled rows that still have their bytes")
    func resetsRetryableRows() throws {
        // The old button called `sweep()` and nothing else, and `dueMedia` excludes `failed` rows
        // by predicate — so it could not move the rows its own copy named.
        // `resetForManualRetry()` already existed and does all three things; it was only ever
        // called from TodayScreen.
        let context = try makeContext()
        let store = makeStore()
        let row = try seedMedia(
            in: context, store: store, state: .failed, withBytes: true, attempts: 6
        )
        row.nextAttemptAt = Date().addingTimeInterval(600)
        try context.save()

        let prepared = SyncUploadsModel.prepareRetry(in: context, store: store)

        #expect(prepared == 1)
        #expect(row.state == .staged, "returned to the queue")
        #expect(row.attemptCount == 0, "attempt count reset")
        #expect(row.nextAttemptAt == nil, "persisted backoff cleared")
    }

    @Test("it leaves a stalled row whose bytes are gone exactly where it is")
    func doesNotResetUnretryableRows() throws {
        // Resetting one would queue it to fail again on a file that is not there, and burn the
        // ladder doing it.
        let context = try makeContext()
        let store = makeStore()
        let row = try seedMedia(
            in: context, store: store, state: .failed, withBytes: false, attempts: 6
        )

        #expect(SyncUploadsModel.prepareRetry(in: context, store: store) == 0)
        #expect(row.state == .failed)
        #expect(row.attemptCount == 6)
    }

    // MARK: What it says afterwards

    private func counts(waiting: Int = 0, stalled: Int = 0, withoutBytes: Int = 0) -> SyncCounts {
        SyncCounts(waitingMedia: waiting, stalledMedia: stalled, stalledWithoutBytes: withoutBytes)
    }

    @Test("offline never claims anything was sent")
    func offlineIsHonest() {
        let outcome = SyncUploadsModel.outcome(
            before: counts(stalled: 3), after: counts(stalled: 3), prepared: 0, isOnline: false
        )
        #expect(outcome == "No connection right now. Nothing was sent.")
    }

    @Test("rows that landed are counted, and the remainder is named")
    func landedIsReported() {
        let outcome = SyncUploadsModel.outcome(
            before: counts(waiting: 5), after: counts(waiting: 2), prepared: 0, isOnline: true
        )
        #expect(outcome == "3 finished. 2 still to go.")
    }

    @Test("an emptied queue says so")
    func clearedIsReported() {
        let outcome = SyncUploadsModel.outcome(
            before: counts(waiting: 2), after: counts(), prepared: 0, isOnline: true
        )
        #expect(outcome == "Everything's uploaded.")
    }

    /// **The sentence this phase exists to remove** was "Nothing moved yet. It'll keep trying on its
    /// own." — reassuring about ten rows that nothing would ever retry. Every branch now says why.
    @Test("nothing moving inside the window still reports a concrete reason")
    func nothingMovedStillSaysWhy() {
        // Rows were picked back up; the upload just has not finished inside the window.
        let picked = SyncUploadsModel.outcome(
            before: counts(stalled: 12), after: counts(waiting: 12), prepared: 12, isOnline: true
        )
        #expect(picked == "12 files picked back up — still uploading.")

        // Nothing could be picked up, because none of them has bytes left.
        let gone = SyncUploadsModel.outcome(
            before: counts(stalled: 2, withoutBytes: 2),
            after: counts(stalled: 2, withoutBytes: 2),
            prepared: 0,
            isOnline: true
        )
        #expect(gone.contains("no longer on this phone"))

        // Online, bytes present, nothing accepted it. Said plainly rather than reassuringly.
        let stuck = SyncUploadsModel.outcome(
            before: counts(waiting: 4), after: counts(waiting: 4), prepared: 0, isOnline: true
        )
        #expect(stuck == "Still stuck — nothing accepted the retry.")
    }

    @Test("no outcome sentence is reassuring about rows nothing will retry")
    func neverFalselyReassuring() {
        let all: [String] = [
            SyncUploadsModel.outcome(
                before: counts(stalled: 10), after: counts(stalled: 10),
                prepared: 0, isOnline: true
            ),
            SyncUploadsModel.outcome(
                before: counts(stalled: 10), after: counts(stalled: 10),
                prepared: 0, isOnline: false
            ),
        ]
        for line in all {
            #expect(!line.contains("keep trying on its own"))
            #expect(!line.lowercased().contains("!"))
        }
    }
}

// MARK: - Never show a control that cannot act

@MainActor
@Suite("Phase 81 — the retry control is disabled when it cannot act")
struct RetryControlEnablementTests {

    private func model(
        online: Bool,
        state: MediaUploadState?
    ) throws -> SyncUploadsModel {
        let context = try makeContext()
        let store = makeStore()
        if let state { _ = try seedMedia(in: context, store: store, state: state, withBytes: true) }
        return SyncUploadsModel(
            // No sweep needed: every assertion here is about enablement and counts, not dispatch.
            sweep: {},
            context: context,
            store: store,
            reachability: NetworkReachability(fixed: online),
            settleWindow: .milliseconds(1)
        )
    }

    @Test("offline disables it, and the row says why rather than going quiet")
    func offlineDisables() throws {
        let model = try model(online: false, state: .failed)

        #expect(model.canRetry == false)
        let reason = try #require(model.retryDisabledReason)
        #expect(reason.contains("No connection"))
        // Not an error and not a scold — a fact about the radio.
        #expect(!reason.lowercased().contains("error"))
        #expect(model.status == .offline)
    }

    @Test("online with something stalled enables it")
    func onlineWithWorkEnables() throws {
        let model = try model(online: true, state: .failed)
        #expect(model.canRetry)
        #expect(model.retryDisabledReason == nil)
    }

    @Test("an empty queue offers no retry at all")
    func nothingToDoOffersNothing() throws {
        let model = try model(online: true, state: nil)
        #expect(model.canRetry == false, "a retry beside 'Up to date' is furniture")
        #expect(model.status == .upToDate)
    }

    /// The invariant the whole phase turns on: the Settings row and this screen are the same read.
    @Test("the Settings row value and the screen's counts are one model")
    func oneModelBothSurfaces() throws {
        let model = try model(online: true, state: .failed)
        #expect(SyncCounts.rowValue(model.status) == "1 stopped")
        #expect(model.counts.stalledMedia == 1)
        #expect(model.rows.count == 1, "and the per-file list shows the same row")
    }
}

// MARK: - Phase 85: one fetch, two views of it

/// The counts and the per-file list are the same rows read two ways. Reading the table twice was
/// twice the work on the main actor, and two chances to disagree between fetches while a background
/// upload delegate writes to the store.
@MainActor
@Suite("Phase 85 — the counts and the list read one fetch")
struct OneFetchTests {

    @Test("reading from a fetched set gives the same answer as fetching inside")
    func bothEntryPointsAgree() throws {
        let context = try makeContext()
        let store = makeStore()
        _ = try seedMedia(in: context, store: store, state: .staged, withBytes: true)
        _ = try seedMedia(in: context, store: store, state: .failed, withBytes: true)
        _ = try seedMedia(in: context, store: store, state: .failed, withBytes: false)
        _ = try seedMedia(in: context, store: store, state: .complete, withBytes: true)

        let media = SyncCounts.outstandingMedia(in: context)
        let shared = SyncCounts.read(outstandingMedia: media, context: context, store: store)
        let fetched = SyncCounts.read(context: context, store: store)

        #expect(shared == fetched, "the convenience overload must not be a second definition")
        #expect(shared.waitingMedia == 1)
        #expect(shared.stalledMedia == 2)
        #expect(shared.stalledWithoutBytes == 1)
    }

    @Test("the one predicate excludes complete and deleted rows for every caller")
    func onePredicateForEveryone() throws {
        let context = try makeContext()
        let store = makeStore()
        _ = try seedMedia(in: context, store: store, state: .complete, withBytes: true)
        let deleted = try seedMedia(in: context, store: store, state: .staged, withBytes: true)
        deleted.deletedAt = Date()
        try context.save()
        _ = try seedMedia(in: context, store: store, state: .uploading, withBytes: true)

        let media = SyncCounts.outstandingMedia(in: context)

        #expect(media.count == 1, "complete and deleted are both out")
        #expect(SyncUploadsModel.readRows(from: media, store: store).count == 1)
    }

    @Test("the list and the counts describe the same rows, structurally")
    func listAndCountsCannotDisagree() throws {
        let context = try makeContext()
        let store = makeStore()
        for state in [MediaUploadState.staged, .uploading, .uploaded, .failed] {
            _ = try seedMedia(in: context, store: store, state: state, withBytes: true)
        }

        let media = SyncCounts.outstandingMedia(in: context)
        let counts = SyncCounts.read(outstandingMedia: media, context: context, store: store)
        let rows = SyncUploadsModel.readRows(from: media, store: store)

        // Not "these two happen to match" — they are the same array, mapped twice.
        #expect(rows.count == counts.waitingMedia + counts.stalledMedia)
        #expect(rows.filter { $0.state == .failed }.count == counts.stalledMedia)
    }
}
