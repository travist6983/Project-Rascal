import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The local-over-server merge, which exists because of a real device observation: a photo
/// mission completed offline kept showing as not done, while a text answer on the same screen
/// showed done immediately. Same action, two outcomes, decided by network timing.
@MainActor
@Suite("Today board merge")
struct TodayBoardTests {

    private func assignment(
        id: UUID = UUID(),
        slot: String = "mission",
        kind: String = "photo",
        mode: String = "media",
        status: AssignmentStatus = .pending
    ) -> AssignmentResponse {
        AssignmentResponse(
            id: id, slot: slot, body: "Take a photo", kind: kind, completionMode: mode,
            theme: nil, status: status, assignedOn: "2026-08-08", expiresOn: "2026-08-22",
            promptId: nil, isCustom: false, unlockAtAge: nil
        )
    }

    private func response(
        today: [AssignmentResponse] = [],
        waiting: [AssignmentResponse] = [],
        done: [AssignmentResponse] = []
    ) -> TodayResponse {
        TodayResponse(
            date: "2026-08-08",
            child: ChildSummary(id: UUID(), name: "Rascal", ageMonths: 62),
            today: today, waiting: waiting, doneToday: done
        )
    }

    private func entry(for assignmentId: UUID?, sync: SyncState = .pending) -> Entry {
        let entry = Entry(childId: UUID(), assignmentId: assignmentId, occurredAt: Date(), body: "done it")
        entry.sync = sync
        return entry
    }

    // MARK: The defect this fixes

    @Test("an unsynced completion renders as done immediately")
    func unsyncedCompletionIsDone() {
        let target = assignment()
        let board = TodayBoard.merge(
            response: response(today: [target]),
            entries: [entry(for: target.id, sync: .pending)],
            media: []
        )

        // The server still says pending. The parent still did it.
        #expect(board.today.isEmpty)
        #expect(board.doneToday.count == 1)
        #expect(board.doneToday.first?.isDone == true)
        #expect(board.doneToday.first?.isAwaitingSync == true)
    }

    @Test("a failed sync does not undo the completion")
    func failedSyncStaysDone() {
        let target = assignment()
        let board = TodayBoard.merge(
            response: response(today: [target]),
            entries: [entry(for: target.id, sync: .failed)],
            media: []
        )

        // Past the backoff cap the upload is a problem; the mission is still finished. That is
        // a fact about the parent's evening, not about the network.
        #expect(board.doneToday.count == 1)
        #expect(board.today.isEmpty)
    }

    @Test("the card does not duplicate when the server catches up")
    func noDuplicateOnceSynced() {
        let target = assignment(status: .done)
        // The server has moved it to done_today, and the local entry still completes it.
        let board = TodayBoard.merge(
            response: response(done: [target]),
            entries: [entry(for: target.id, sync: .synced)],
            media: []
        )

        #expect(board.doneToday.count == 1, "one completion must not render as two cards")
    }

    @Test("nothing visibly changes when the sync lands")
    func stableAcrossSync() {
        let target = assignment()
        let before = TodayBoard.merge(
            response: response(today: [target]),
            entries: [entry(for: target.id, sync: .pending)],
            media: []
        )
        // The server now agrees and moves it itself.
        let after = TodayBoard.merge(
            response: response(done: [assignment(id: target.id, status: .done)]),
            entries: [entry(for: target.id, sync: .synced)],
            media: []
        )

        #expect(before.doneToday.map(\.id) == after.doneToday.map(\.id))
        #expect(before.today.isEmpty && after.today.isEmpty)
    }

    @Test("a waiting assignment completed locally moves to done")
    func waitingAlsoMerges() {
        let target = assignment()
        let board = TodayBoard.merge(
            response: response(waiting: [target]),
            entries: [entry(for: target.id)],
            media: []
        )
        #expect(board.waiting.isEmpty)
        #expect(board.doneToday.count == 1)
    }

    @Test("an untouched assignment is left where the server put it")
    func untouchedIsUnchanged() {
        let board = TodayBoard.merge(response: response(today: [assignment()]), entries: [], media: [])
        #expect(board.today.count == 1)
        #expect(board.doneToday.isEmpty)
        #expect(board.today.first?.isDone == false)
    }

    @Test("a deleted local entry stops completing its assignment")
    func deletedEntryDoesNotComplete() {
        let target = assignment()
        let removed = entry(for: target.id)
        removed.deletedAt = Date()

        let board = TodayBoard.merge(response: response(today: [target]), entries: [removed], media: [])

        // Deleting an entry releases its assignment server-side; the board must agree.
        #expect(board.today.count == 1)
        #expect(board.doneToday.isEmpty)
    }

    @Test("a freeform entry completes nothing")
    func freeformDoesNotAffectTheBoard() {
        let board = TodayBoard.merge(
            response: response(today: [assignment()]),
            entries: [entry(for: nil)],
            media: []
        )
        #expect(board.today.count == 1)
        #expect(board.doneToday.isEmpty)
    }

    // MARK: Progress for the ring

    @Test("progress counts down across files and is weighted by bytes")
    func progressIsByteWeighted() {
        let target = assignment()
        let local = entry(for: target.id)

        // One large, two small: a count-weighted ring would jump to 2/3 while most of the
        // bytes were still outstanding.
        let big = Media(entryId: local.id, kind: "photo", contentType: "image/jpeg", byteCount: 8_000)
        let small1 = Media(entryId: local.id, kind: "photo", contentType: "image/jpeg", byteCount: 1_000)
        let small2 = Media(entryId: local.id, kind: "photo", contentType: "image/jpeg", byteCount: 1_000)
        small1.state = .complete
        small2.state = .complete

        let board = TodayBoard.merge(response: response(today: [target]), entries: [local], media: [big, small1, small2])
        let progress = board.doneToday.first?.mediaProgress

        #expect(progress?.total == 3)
        #expect(progress?.complete == 2)
        #expect(progress?.remaining == 1)
        #expect((progress?.fraction ?? 1) < 0.3, "two small files of ten are not most of the work")
        #expect(progress?.isFinished == false)
    }

    @Test("partial bytes on an in-flight file move the ring")
    func inFlightBytesCount() {
        let target = assignment()
        let local = entry(for: target.id)
        let uploading = Media(entryId: local.id, kind: "photo", contentType: "image/jpeg", byteCount: 1_000)
        uploading.state = .uploading
        uploading.bytesSent = 500

        let board = TodayBoard.merge(response: response(today: [target]), entries: [local], media: [uploading])
        let fraction = board.doneToday.first?.mediaProgress?.fraction ?? 0

        // Measured, not a spinner pretending to measure.
        #expect(fraction > 0.4 && fraction < 0.6)
    }

    @Test("failures are counted separately and end the progress")
    func failuresFinishTheRing() {
        let target = assignment()
        let local = entry(for: target.id)
        let ok = Media(entryId: local.id, kind: "photo", contentType: "image/jpeg", byteCount: 100)
        let bad = Media(entryId: local.id, kind: "photo", contentType: "image/jpeg", byteCount: 100)
        ok.state = .complete
        bad.state = .failed

        let progress = TodayBoard.merge(
            response: response(today: [target]), entries: [local], media: [ok, bad]
        ).doneToday.first?.mediaProgress

        #expect(progress?.failed == 1)
        #expect(progress?.hasFailures == true)
        // Nothing is still moving, so the ring should stop rather than sit at 50% forever.
        #expect(progress?.isFinished == true)
        #expect(progress?.remaining == 0)
    }

    @Test("an entry with no media has no ring at all")
    func textEntryHasNoProgress() {
        let target = assignment(kind: "question", mode: "text")
        let board = TodayBoard.merge(
            response: response(today: [target]),
            entries: [entry(for: target.id)],
            media: []
        )
        #expect(board.doneToday.first?.mediaProgress == nil)
    }
}
