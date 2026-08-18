import Foundation
import SwiftData

/// Reconciles the staging directory against what SwiftData believes.
///
/// Two sources of truth exist by necessity — a filesystem and a database — and they drift:
/// a force quit between writing a file and saving a row, an entry deleted while its upload was
/// in flight, a container restored without its files. This is the one place that decides which
/// side wins, so the decision is not spread across the uploader and the composer.
@MainActor
struct StagingSweeper {
    let store: StagingStore
    let context: ModelContext

    /// How long a file with no media row is presumed to be in somebody's hands rather than debris.
    ///
    /// **This window is the difference between a recording kept and a recording deleted.** A take
    /// is written to staging the instant recording stops, and it does not get a `Media` row until
    /// the composer saves — so between those two moments a staged file is indistinguishable, from
    /// here, from crash debris. The sweep runs on every foreground (`RootView`), and locking the
    /// screen mid-recording is a background-then-foreground round trip, so the unqualified rule
    /// deleted the take on the way back to the review screen: the parent returned to a scrubber
    /// pointing at a file that had just been removed.
    ///
    /// A day rather than minutes because the cost of waiting is a few megabytes of debris living
    /// one day longer, and the cost of being wrong is somebody's recording. Genuinely abandoned
    /// files are still collected — one sweep later.
    static let orphanGrace: TimeInterval = 24 * 60 * 60

    struct Result: Equatable {
        /// Originals removed because their upload finished and a thumbnail exists.
        var disposedOriginals = 0
        /// Files with no media row at all.
        var orphanFiles = 0
        /// Files with no media row that were left alone because they are younger than
        /// `orphanGrace` — a take still in an open composer looks exactly like this.
        var youngOrphansKept = 0
        /// Everything belonging to a deleted entry.
        var deletedEntryFiles = 0
        /// Complete rows whose local copies are gone. Not lost — refetchable through
        /// `GET /media/{id}/url`, which is why this is a flag and not an error.
        var flaggedForRefetch = 0
    }

    /// `now` is injected so the grace window can be tested without sleeping or back-dating a
    /// file, the same way `MediaCoordinator.sweep(now:)` takes one.
    @discardableResult
    func sweep(now: Date = Date()) -> Result {
        var result = Result()
        let media = (try? context.fetch(FetchDescriptor<Media>())) ?? []
        let byId = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })

        let liveEntryIds = Set(
            ((try? context.fetch(FetchDescriptor<Entry>())) ?? [])
                .filter { $0.deletedAt == nil }
                .map(\.id)
        )

        // 1. Files the database knows nothing about. A crash between writing bytes and saving
        //    a row leaves these, and nothing will ever pick them up — but so does a recording
        //    the parent has not saved yet, which is why age decides and not just absence.
        for url in store.stagedFiles() {
            guard let id = store.mediaId(of: url) else {
                // Not one of ours. Left alone rather than deleted — this directory is the
                // app's, but guessing at an unrecognised filename is how real data dies.
                continue
            }
            guard let row = byId[id] else {
                // An unreadable modification date counts as old: not knowing a file's age is not
                // evidence that somebody is holding it.
                let age = store.modifiedAt(of: url).map { now.timeIntervalSince($0) }
                if let age, age < Self.orphanGrace {
                    result.youngOrphansKept += 1
                    continue
                }
                try? FileManager.default.removeItem(at: url)
                result.orphanFiles += 1
                continue
            }
            // 2. The entry went away. Its media goes with it.
            if row.deletedAt != nil || !liveEntryIds.contains(row.entryId) {
                try? FileManager.default.removeItem(at: url)
                result.deletedEntryFiles += 1
            }
        }

        for row in media {
            // 3. The rule: uploaded *and* thumbnailed. Only the original goes; the thumbnail
            //    is what makes the timeline render without refetching.
            if row.stagedOriginalIsDisposable, let ext = row.stagedExtension {
                let original = store.originalURL(for: row.id, ext: ext)
                if store.exists(original) {
                    try? FileManager.default.removeItem(at: original)
                    row.stagedExtension = nil
                    result.disposedOriginals += 1
                }
            }

            // 4. Complete, but nothing local left to show. The bytes are safe in storage, so
            //    this is a cache miss rather than a loss — `presign_get` can fetch them back.
            //    Flagged rather than silently repaired so the next render knows to go and get
            //    them instead of showing an empty frame.
            if row.isComplete, !row.hasThumbnail, !store.exists(store.thumbnailURL(for: row.id)) {
                result.flaggedForRefetch += 1
            }
        }

        try? context.save()
        return result
    }

    /// Media rows whose bytes are only in storage. Phase 3's timeline fetches these through
    /// `GET /media/{id}/url`; recorded here so the sweep's finding is actionable rather than
    /// just counted.
    static func needingRefetch(context: ModelContext, store: StagingStore) -> [Media] {
        let all = (try? context.fetch(FetchDescriptor<Media>())) ?? []
        return all.filter { row in
            row.deletedAt == nil && row.isComplete && !store.exists(store.thumbnailURL(for: row.id))
        }
    }
}
