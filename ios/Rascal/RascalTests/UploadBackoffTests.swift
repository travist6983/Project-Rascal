import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Retry scheduling: the backoff curve, the jitter that breaks a convoy, and the sweep
/// ordering that stops one dead row starving the queue.
///
/// All pure arithmetic and fetch ordering — no network, no session, no real clock.
@MainActor
@Suite("Upload backoff and sweep ordering")
struct UploadBackoffTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([Entry.self, Media.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A media row and the synced entry it hangs off.
    ///
    /// The entry is not incidental: `upload-url` needs an `entry_id` the server recognises, so
    /// a media row whose entry has not synced is not due — it is waiting. Building rows without
    /// one would test a state that cannot occur.
    @discardableResult
    private func media(
        in context: ModelContext,
        state: MediaUploadState = .staged,
        nextAttemptAt: Date? = nil,
        attempts: Int = 0,
        entrySync: SyncState = .synced
    ) -> Media {
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "with a photo")
        entry.sync = entrySync
        context.insert(entry)

        let row = Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 1)
        row.state = state
        row.nextAttemptAt = nextAttemptAt
        row.attemptCount = attempts
        context.insert(row)
        return row
    }

    // MARK: Curve

    @Test("the delay grows and then stops growing")
    func exponentialAndCapped() {
        // Jitter pinned to 1 so the curve itself is under test.
        let delays = (1...10).map { UploadBackoff.delay(forAttempt: $0, jitter: 1) }
        for (earlier, later) in zip(delays, delays.dropFirst()) {
            #expect(later >= earlier, "the curve must never go backwards")
        }
        #expect(delays.first == UploadBackoff.base)
        #expect(delays.last == UploadBackoff.ceiling, "it has to stop somewhere")
    }

    @Test("attempts are capped, and the row ends up failed rather than retrying forever")
    func capsAttempts() {
        #expect(UploadBackoff.nextAttempt(after: UploadBackoff.maxAttempts - 1, jitter: 1) != nil)
        #expect(UploadBackoff.nextAttempt(after: UploadBackoff.maxAttempts, jitter: 1) == nil)
    }

    // MARK: Jitter — the convoy

    @Test("rows failing together do not become eligible together")
    func jitterBreaksTheConvoy() throws {
        let context = try makeContext()
        let now = Date()
        // Five photos on one entry, all failing the instant a connection drops.
        let rows = (0..<5).map { _ in media(in: context) }
        for row in rows { row.recordAttemptFailure(now: now) }

        let times = rows.compactMap(\.nextAttemptAt)
        #expect(times.count == 5)
        // Without jitter these are identical, they retry in lockstep, and they fail together
        // again — a tightening convoy that never resolves.
        #expect(Set(times).count > 1, "identical retry times are the failure this exists to prevent")
    }

    @Test("jitter stays within a band rather than being arbitrary")
    func jitterIsBounded() {
        let unjittered = UploadBackoff.delay(forAttempt: 3, jitter: 1)
        for _ in 0..<200 {
            let actual = UploadBackoff.delay(forAttempt: 3)
            // Spread, but recognisably the same backoff. Full 0...delay jitter can retry
            // almost immediately, which on a dropped connection just burns a request.
            #expect(actual >= unjittered * 0.5)
            #expect(actual <= unjittered * 1.5)
        }
    }

    // MARK: Eligibility

    @Test("a row that has never been tried is due immediately")
    func neverTriedIsDue() {
        #expect(UploadBackoff.isEligible(nextAttemptAt: nil))
    }

    @Test("a row scheduled for the future is not due yet")
    func futureIsNotDue() {
        let now = Date()
        #expect(!UploadBackoff.isEligible(nextAttemptAt: now.addingTimeInterval(60), now: now))
        #expect(UploadBackoff.isEligible(nextAttemptAt: now.addingTimeInterval(-1), now: now))
    }

    // MARK: Ordering — the starvation case

    @Test("the sweep is ordered by when rows became due, not by age")
    func ordersByDueTime() throws {
        let context = try makeContext()
        let now = Date()

        // The old, repeatedly-failing row: created first, so oldest-first would put it in
        // front of everything forever.
        let stubborn = media(in: context, nextAttemptAt: now.addingTimeInterval(-1), attempts: 4)
        // A photo just taken, never attempted.
        let fresh = media(in: context, nextAttemptAt: nil)

        let due = MediaCoordinator.dueMedia(in: context, now: now)

        #expect(due.count == 2)
        #expect(due.first?.id == fresh.id, "a never-tried photo goes before one that failed four times")
        #expect(due.last?.id == stubborn.id)
    }

    @Test("a permanently failing row cannot starve the queue behind it")
    func noHeadOfLineStarvation() throws {
        let context = try makeContext()
        let now = Date()

        let doomed = media(in: context)
        // It fails; its own eligibility moves out of the way.
        doomed.recordAttemptFailure(now: now)
        let others = (0..<3).map { _ in media(in: context) }

        let due = MediaCoordinator.dueMedia(in: context, now: now)

        // The doomed row is not even in this pass — it scheduled itself for later.
        #expect(due.count == 3)
        #expect(!due.contains { $0.id == doomed.id })
        #expect(Set(due.map(\.id)) == Set(others.map(\.id)))
    }

    @Test("rows past the cap drop out of the sweep entirely and are surfaced instead")
    func failedRowsLeaveTheQueue() throws {
        let context = try makeContext()
        let row = media(in: context)
        for _ in 0...UploadBackoff.maxAttempts { row.recordAttemptFailure() }

        #expect(row.state == .failed)
        #expect(MediaCoordinator.dueMedia(in: context).isEmpty, "a failed row must not spin")
        #expect(MediaCoordinator.failedMedia(in: context).count == 1, "but it must be visible")
    }

    @Test("a manual retry skips the backoff")
    func manualRetryIsImmediate() throws {
        let context = try makeContext()
        let row = media(in: context)
        for _ in 0...UploadBackoff.maxAttempts { row.recordAttemptFailure() }
        #expect(row.state == .failed)

        row.resetForManualRetry()

        // Someone pressed a button. Making them wait out an exponential delay would be absurd.
        #expect(row.state == .staged)
        #expect(row.nextAttemptAt == nil)
        #expect(MediaCoordinator.dueMedia(in: context).count == 1)
    }

    // MARK: Which leg gets retried

    @Test("an uploaded row is retried without re-sending the file")
    func uploadedRetriesCompletionOnly() throws {
        let context = try makeContext()
        // The PUT landed; only the acknowledgement failed.
        _ = media(in: context, state: .uploaded)

        let due = MediaCoordinator.dueMedia(in: context)

        #expect(due.count == 1)
        #expect(due.first?.state == .uploaded,
                "re-uploading would spend a parent's cellular data to reach the state it is in")
    }

    @Test("a row already in flight is not started twice")
    func skipsInFlight() throws {
        let context = try makeContext()
        let inFlight = media(in: context)
        #expect(MediaCoordinator.dueMedia(in: context, excluding: [inFlight.id]).isEmpty)
    }

    // MARK: Media waits for its entry

    @Test("media whose entry has not synced is not due")
    func waitsForItsEntry() throws {
        let context = try makeContext()
        media(in: context, entrySync: .pending)

        // upload-url would 404 on an entry_id the server has never seen. Attempting it would
        // burn a retry and push the backoff out for a row that could not have succeeded.
        #expect(MediaCoordinator.dueMedia(in: context).isEmpty)
    }

    @Test("media becomes due once its entry lands")
    func becomesDueAfterEntrySyncs() throws {
        let context = try makeContext()
        let row = media(in: context, entrySync: .pending)
        #expect(MediaCoordinator.dueMedia(in: context).isEmpty)

        let entry = try #require(
            ((try? context.fetch(FetchDescriptor<Entry>())) ?? []).first { $0.id == row.entryId }
        )
        entry.sync = .synced

        #expect(MediaCoordinator.dueMedia(in: context).count == 1)
    }

    @Test("media of a failing entry stays out of the queue rather than failing alongside it")
    func failingEntryDoesNotBurnMediaAttempts() throws {
        let context = try makeContext()
        let row = media(in: context, entrySync: .failed)

        #expect(MediaCoordinator.dueMedia(in: context).isEmpty)
        // Untouched: no attempt spent, no backoff pushed out. When the entry finally lands
        // its photo uploads on the first try.
        #expect(row.attemptCount == 0)
        #expect(row.state == .staged)
    }

    @Test("a completed or deleted row is never swept")
    func skipsFinishedAndDeleted() throws {
        let context = try makeContext()
        _ = media(in: context, state: .complete)
        let deleted = media(in: context)
        deleted.deletedAt = Date()

        #expect(MediaCoordinator.dueMedia(in: context).isEmpty)
        // Neither is outstanding: one is finished, and the other belongs to something the
        // parent deleted. Counting a deleted entry's media as "still saving" would show a
        // count for work nobody is waiting on.
        #expect(MediaCoordinator.outstandingCount(in: context) == 0)
    }
}
