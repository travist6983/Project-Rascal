import Foundation
import SwiftData

/// Every number the sync surface shows, read once, from one place.
///
/// **Two numbers that can disagree is the defect this type exists to remove.** The card previously
/// said "2 left" and "2 files still to upload" in one breath and "10 files stopped trying" in the
/// next, and a reader could not tell whether the total was 2 or 12. That was not a rendering
/// mistake: the counter and the headline were two independent subtractions over three separate
/// fetches, and a background upload delegate can write to the store between them.
///
/// There were seven distinct definitions of "outstanding" in the tree. This is one, over one fetch
/// of `Media` and one of `Entry`, so the parts are guaranteed to be arithmetic on the same rows
/// rather than four answers to four slightly different questions.
///
/// It keeps the split that phase 20 introduced deliberately — waiting and stalled stay two
/// sentences, because one is waiting on a connection and will finish by itself and the other has
/// stopped and needs asking again. What phase 20 did not have was a guarantee that the two
/// sentences were counting the same rows. That is what changed.
struct SyncCounts: Equatable, Sendable {

    /// Local entries the server has not acknowledged.
    var unsyncedEntries = 0
    /// Deletions not yet sent.
    var pendingDeletions = 0
    /// Media on its way: `staged`, `uploading` or `uploaded`. Never `failed`, never `complete`.
    var waitingMedia = 0
    /// Media past the retry cap. **Nothing retries these** until somebody asks.
    var stalledMedia = 0
    /// The subset of `stalledMedia` whose staged bytes are gone from disk.
    ///
    /// A different thing from one that can still be retried, and the screen must not offer the
    /// same action for both — the same class of lie phase 80 fixed at the entry level.
    var stalledWithoutBytes = 0

    /// Work still genuinely on its way. Excludes stalled rows, which are not a countdown.
    var waiting: Int { unsyncedEntries + pendingDeletions + waitingMedia }
    var total: Int { waiting + stalledMedia }
    var isClear: Bool { total == 0 }

    // MARK: The one read

    /// One fetch of `Media`, one of `Entry`, and arithmetic.
    ///
    /// Deliberately not `childId`-scoped, and that is not an oversight: device-wide work queues are
    /// unscoped on purpose so a second child's offline writes are not stranded (`ios/CLAUDE.md`).
    /// The previous surface mixed an archive-wide media count with a per-child entry count and
    /// presented the sum as one number.
    @MainActor
    static func read(context: ModelContext, store: StagingStore = StagingStore()) -> SyncCounts {
        read(outstandingMedia: outstandingMedia(in: context), context: context, store: store)
    }

    /// Every media row that is not complete and not deleted, in one fetch.
    ///
    /// Exposed so a caller that needs both the counts *and* the rows reads the table once. The
    /// counts and the per-file list are two views of the same set, and fetching twice to build
    /// them was two chances to disagree as well as twice the work — on the main actor, on every
    /// foreground.
    @MainActor
    static func outstandingMedia(in context: ModelContext) -> [Media] {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { $0.deletedAt == nil && !$0.isComplete }
    }

    /// The arithmetic, over a set somebody already has in hand.
    @MainActor
    static func read(
        outstandingMedia media: [Media],
        context: ModelContext,
        store: StagingStore = StagingStore()
    ) -> SyncCounts {
        var counts = SyncCounts(
            unsyncedEntries: (try? context.fetchCount(EntrySync.unsyncedDescriptor())) ?? 0,
            pendingDeletions: (try? context.fetchCount(EntrySync.pendingDeletionDescriptor())) ?? 0
        )

        for row in media {
            if row.state == .failed {
                counts.stalledMedia += 1
                if !hasStagedBytes(row, in: store) { counts.stalledWithoutBytes += 1 }
            } else {
                counts.waitingMedia += 1
            }
        }
        return counts
    }

    /// The same existence check `EntryDetailScreen.stagedOriginal` uses, and for the same reason:
    /// a row whose bytes are gone cannot be retried, whatever its state says.
    static func hasStagedBytes(_ row: Media, in store: StagingStore) -> Bool {
        guard let ext = row.stagedExtension else { return false }
        return store.exists(store.originalURL(for: row.id, ext: ext))
    }

    // MARK: The one status sentence

    /// What the single Settings row says, in priority order. **First match wins, and there is only
    /// ever one** — the old card said three things at once and left the reader to add them up.
    enum Status: Equatable, Sendable {
        /// No network path. Nothing can move, and no control may claim otherwise.
        case offline
        case stopped(Int)
        case waiting(Int)
        case upToDate
    }

    /// Offline outranks everything, because it is the only one of these that changes what the
    /// parent can *do*. Stalled outranks waiting because it is the half that needs a person.
    static func status(_ counts: SyncCounts, isOnline: Bool) -> Status {
        if !isOnline { return .offline }
        if counts.stalledMedia > 0 { return .stopped(counts.stalledMedia) }
        if counts.waiting > 0 { return .waiting(counts.waiting) }
        return .upToDate
    }

    /// The trailing value on the Settings row. Short, because it sits beside a chevron.
    static func rowValue(_ status: Status) -> String {
        switch status {
        case .offline: "Offline"
        case .stopped(let n): "\(n) stopped"
        case .waiting(let n): "\(n) waiting"
        case .upToDate: "Up to date"
        }
    }

    // MARK: What the upload group says, still as two sentences

    /// The waiting sentence, or nothing when nothing is waiting.
    static func waitingLine(_ counts: SyncCounts) -> String? {
        guard counts.waiting > 0 else { return nil }
        var parts: [String] = []
        let writes = counts.unsyncedEntries + counts.pendingDeletions
        if writes > 0 { parts.append(writes == 1 ? "1 entry" : "\(writes) entries") }
        if counts.waitingMedia > 0 {
            parts.append(counts.waitingMedia == 1 ? "1 file" : "\(counts.waitingMedia) files")
        }
        return "\(parts.joined(separator: " and ")) still to upload."
    }

    /// The stalled sentence, kept separate per phase 20. Never urgent, never red.
    ///
    /// It no longer promises what "Retry now" will achieve. The old copy said retry "picks them
    /// back up", which was false: the sweep excludes `failed` rows by predicate, so the button
    /// could not move the rows its own sentence named.
    static func stalledLine(_ counts: SyncCounts) -> String? {
        guard counts.stalledMedia > 0 else { return nil }
        let subject = counts.stalledMedia == 1 ? "1 file has" : "\(counts.stalledMedia) files have"
        guard counts.stalledWithoutBytes > 0 else {
            return "\(subject) stopped trying. They're still on this phone."
        }
        // The honest version of the harder case: some of these cannot be retried at all.
        let gone = counts.stalledWithoutBytes
        let goneClause = gone == counts.stalledMedia
            ? (gone == 1 ? "It is no longer on this phone." : "They are no longer on this phone.")
            : "\(gone) of them \(gone == 1 ? "is" : "are") no longer on this phone."
        return "\(subject) stopped trying. \(goneClause)"
    }

    /// How many stalled rows a retry could actually move.
    var retryable: Int { max(0, stalledMedia - stalledWithoutBytes) }
}
