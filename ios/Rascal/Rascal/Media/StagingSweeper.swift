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

    struct Result: Equatable {
        /// Originals removed because their upload finished and a thumbnail exists.
        var disposedOriginals = 0
        /// Files with no media row at all.
        var orphanFiles = 0
        /// Everything belonging to a deleted entry.
        var deletedEntryFiles = 0
        /// Complete rows whose local copies are gone. Not lost — refetchable through
        /// `GET /media/{id}/url`, which is why this is a flag and not an error.
        var flaggedForRefetch = 0
    }

    @discardableResult
    func sweep() -> Result {
        var result = Result()
        let media = (try? context.fetch(FetchDescriptor<Media>())) ?? []
        let byId = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })

        let liveEntryIds = Set(
            ((try? context.fetch(FetchDescriptor<Entry>())) ?? [])
                .filter { $0.deletedAt == nil }
                .map(\.id)
        )

        // 1. Files the database knows nothing about. A crash between writing bytes and saving
        //    a row leaves these, and nothing will ever pick them up.
        for url in store.stagedFiles() {
            guard let id = store.mediaId(of: url) else {
                // Not one of ours. Left alone rather than deleted — this directory is the
                // app's, but guessing at an unrecognised filename is how real data dies.
                continue
            }
            guard let row = byId[id] else {
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
