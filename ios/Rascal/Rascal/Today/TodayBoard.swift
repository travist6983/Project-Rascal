import Foundation
import SwiftData

/// What Today actually renders: the server's board with local truth merged over it.
///
/// The server is the source of truth for *what was assigned* — that stays. It is not the source
/// of truth for *what the parent just did*. Rendering server state alone produced the defect
/// this exists to fix: a photo mission completed offline kept showing as not done, while a text
/// answer on the same screen showed done immediately, because one synced and the other didn't.
/// Same action, two outcomes, decided by network timing.
///
/// A completion is a fact about the parent's evening. Whether the server has heard about it yet
/// is a fact about the network, and the two must not be conflated on screen.
struct TodayBoard: Equatable {
    let date: String
    let child: ChildSummary
    var today: [BoardItem]
    var waiting: [BoardItem]
    var doneToday: [BoardItem]

    /// An assignment plus whatever the client knows that the server may not.
    struct BoardItem: Equatable, Identifiable {
        let assignment: AssignmentResponse
        /// The local entry completing it, if there is one.
        let localEntryId: UUID?
        /// Media still in flight for that entry, for the ring in F-2.
        let mediaProgress: MediaProgress?

        var id: UUID { assignment.id }

        /// Done if the server says so **or** if a local entry completes it. The local one is
        /// what makes the card land in the right place the instant Save is tapped.
        var isDone: Bool {
            assignment.status == .done || localEntryId != nil
        }

        /// Completed locally, not yet acknowledged. The card is done; the upload is not.
        var isAwaitingSync: Bool {
            localEntryId != nil && assignment.status != .done
        }
    }

    /// Byte-level progress across an entry's files, for the ring.
    struct MediaProgress: Equatable {
        var total: Int
        var complete: Int
        var failed: Int
        /// 0…1 across all files, weighted by bytes rather than by count — one large photo
        /// among three small ones should not make the ring jump to 75% and sit there.
        var fraction: Double

        var remaining: Int { max(0, total - complete - failed) }
        var isFinished: Bool { complete + failed >= total }
        var hasFailures: Bool { failed > 0 }
    }

    /// Fold local entries and media over a server response.
    ///
    /// Deduplication is by `assignment_id`: when the sync lands, the server moves the
    /// assignment into `done_today` itself, and without this the card would appear twice —
    /// once because the server says done and once because a local entry says so.
    static func merge(
        response: TodayResponse,
        entries: [Entry],
        media: [Media]
    ) -> TodayBoard {
        let liveEntries = entries.filter { $0.deletedAt == nil }
        // Newest wins if somehow two entries complete one assignment; the archive keeps both,
        // but the board shows one card.
        let entryByAssignment = Dictionary(
            liveEntries.compactMap { entry in entry.assignmentId.map { ($0, entry) } },
            uniquingKeysWith: { first, second in first.createdAt >= second.createdAt ? first : second }
        )

        let mediaByEntry = Dictionary(grouping: media.filter { $0.deletedAt == nil }, by: \.entryId)

        func item(_ assignment: AssignmentResponse) -> BoardItem {
            let entry = entryByAssignment[assignment.id]
            return BoardItem(
                assignment: assignment,
                localEntryId: entry?.id,
                mediaProgress: entry.flatMap { progress(for: mediaByEntry[$0.id] ?? []) }
            )
        }

        var today: [BoardItem] = []
        var waiting: [BoardItem] = []
        var done: [BoardItem] = []

        for assignment in response.today {
            let built = item(assignment)
            built.isDone ? done.append(built) : today.append(built)
        }
        for assignment in response.waiting {
            let built = item(assignment)
            built.isDone ? done.append(built) : waiting.append(built)
        }
        for assignment in response.doneToday {
            // Already done server-side. If a local entry also completes it, that is the same
            // completion having landed — not a second one.
            done.append(item(assignment))
        }

        // Belt and braces: the server should never list one assignment twice, but a card
        // appearing twice is the most visible possible bug and costs one line to rule out.
        var seen = Set<UUID>()
        done = done.filter { seen.insert($0.id).inserted }

        return TodayBoard(
            date: response.date,
            child: response.child,
            today: today,
            waiting: waiting,
            doneToday: done
        )
    }

    private static func progress(for media: [Media]) -> MediaProgress? {
        guard !media.isEmpty else { return nil }

        let totalBytes = media.reduce(0) { $0 + max(1, $1.byteCount) }
        let landedBytes = media.reduce(0) { sum, row in
            sum + (row.isComplete ? max(1, row.byteCount) : Int(Double(max(1, row.byteCount)) * row.uploadFraction))
        }

        return MediaProgress(
            total: media.count,
            complete: media.filter(\.isComplete).count,
            failed: media.filter { $0.state == .failed }.count,
            fraction: totalBytes > 0 ? min(1, Double(landedBytes) / Double(totalBytes)) : 0
        )
    }
}

extension Media {
    /// How much of this file has landed, 0…1.
    ///
    /// The background session reports bytes sent per task, which is written to the row as it
    /// arrives — so this is measured rather than a spinner pretending to be measurement.
    /// A file that has been handed over but not yet reported on reads as 0, which is honest.
    var uploadFraction: Double {
        switch state {
        case .complete, .uploaded: 1
        case .uploading: byteCount > 0 ? min(1, Double(bytesSent) / Double(byteCount)) : 0
        default: 0
        }
    }
}
