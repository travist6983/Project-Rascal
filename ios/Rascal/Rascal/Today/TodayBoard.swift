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

    /// Slots this household was not served, in the order the server sent them.
    ///
    /// **A fourth array rather than a flag on `BoardItem`**, and that is what keeps a locked slot
    /// out of every existing surface. `waiting`, `doneToday`, the expiry chips, the skip gesture and
    /// the widget snapshot all read the three arrays above; none of them can see this one without
    /// somebody deliberately adding it. A `BoardItem` with `isLocked` would have leaked into all of
    /// them by default and been noticed in whichever one nobody checks.
    var locked: [LockedSlot] = []

    // **`access` is deliberately not carried here.** It was, briefly, with a comment claiming two
    // readers — and nothing ever read it. The two decisions it was supposed to serve each read the
    // *response*: `lockedSlots(in:)` below gates the cards, and `TodayModel.observe(_:)` decides the
    // post-trial notice. A board that stored it as well would be a second copy of an entitlement
    // answer, which is the one thing this phase is most careful not to have.

    /// Whether the board draws its **Today** heading.
    ///
    /// **A property rather than a condition inside the view, because the view cannot be tested.**
    /// `TodayBoardView` is a `List`, which `ImageRenderer` will not rasterize, and there is no UI
    /// test target — so the rule was expressible nowhere. It was also a shipped defect: the heading
    /// used to render only when `today` was non-empty, and the moment a free parent answered the
    /// daily question their locked cards were left floating above *Waiting* with nothing naming
    /// them. That is the state a free household is in for the rest of every day.
    var showsTodaySection: Bool { !today.isEmpty || !locked.isEmpty }

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
            doneToday: done,
            // Gated and de-duplicated — see `lockedSlots(in:)`, which is where the one entitlement
            // decision on this side lives.
            locked: lockedSlots(in: response)
        )
    }

    /// The slots to draw as locked, gated and de-duplicated.
    ///
    /// **`isEntitled` is what gates the cards, not `access == .free`.** `.notReported` — the field
    /// absent, which is every build talking to a server older than phase 107 — and `.unrecognised`
    /// — a fourth value from a server newer than this build — both read as entitled, so the board
    /// renders in full. The failure direction must be *"you can see everything"*, never *"here is a
    /// paywall"*: a parent in a tunnel does not get sold to, and a device never decides whether a
    /// household has paid. A server that sends `locked[]` while saying `subscribed` is contradicting
    /// itself; the generous reading wins.
    ///
    /// **Deduplicated by slot**, on the same reasoning the `done_today` dedupe above states: the
    /// server should never list one slot twice, but `ForEach` keys these on `slot`, and duplicate
    /// ids are undefined behaviour in a `List` rather than a merely duplicated card. One line to
    /// rule out.
    private static func lockedSlots(in response: TodayResponse) -> [LockedSlot] {
        guard !response.access.isEntitled else { return [] }
        var seen = Set<String>()
        return response.locked.filter { seen.insert($0.slot).inserted }
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
