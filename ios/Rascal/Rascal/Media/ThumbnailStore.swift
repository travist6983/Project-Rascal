import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Where the timeline gets its pictures.
///
/// **The server has no thumbnails.** `thumb_key` is null on every media row — generation was cut
/// from P0 — so there is no small object to ask for. What exists is the original in private
/// storage, reachable only through a short-lived `GET /media/{id}/url`. So the client makes its
/// own: fetch once, downsample to 400px, write it beside the staged originals, and never fetch
/// that photo again.
///
/// Three consequences worth naming rather than discovering:
///
/// 1. **A photo captured on this phone never downloads at all.** The composer already staged a
///    thumbnail, and this looks on disk first. The download path is for an archive opened on a
///    second device, or a photo whose original the staging sweep has collected.
/// 2. **Video is never downloaded.** A poster frame is not worth pulling a hundred megabytes
///    through someone's cellular plan. A video with no local poster renders as its own tile,
///    which is honest, and a video captured here always has one.
/// 3. **Audio has no thumbnail by design.** A voice entry shows a waveform chip and the first
///    line of its transcript — see `EntryCard`. There is nothing to draw.
///
/// The signed URL is deliberately not stored. It outlives its signature and then fails in a way
/// that reads like the archive lost the file; the bytes are cached, the URL is refetched.
@MainActor
@Observable
final class ThumbnailStore {

    private let api: APIClient
    private let staging: StagingStore

    #if canImport(UIKit)
    /// Decoded and ready to draw. `NSCache` evicts under memory pressure on its own, which is
    /// the whole reason it is here rather than a dictionary — a scroll through five hundred
    /// entries must not be the reason the app is killed.
    private let memory = NSCache<NSUUID, UIImage>()
    #endif

    /// One fetch per media id, however many cards ask for it. A multi-photo entry appearing in
    /// both the timeline and Moments would otherwise download the same picture twice.
    private var inFlight: [UUID: Task<Data?, Never>] = [:]

    /// Ids that came back with nothing. Kept so a scroll past a photo whose bytes are genuinely
    /// gone does not re-request it on every appearance; cleared by a pull-to-refresh, which is
    /// the gesture that means "try again".
    private var unavailable: Set<UUID> = []

    init(api: APIClient, staging: StagingStore = StagingStore()) {
        self.api = api
        self.staging = staging
        #if canImport(UIKit)
        memory.countLimit = 300
        #endif
    }

    #if canImport(UIKit)

    /// Already in memory, for a first render with no flicker. Never touches the disk.
    func cached(_ mediaId: UUID) -> UIImage? {
        memory.object(forKey: mediaId as NSUUID)
    }

    /// The thumbnail for one media row, from memory, then disk, then storage.
    ///
    /// `kind` decides whether the network is allowed: photos may be fetched, video and audio
    /// may not. Returns nil rather than throwing — a missing picture is a tile, never an error
    /// message over someone's archive.
    func image(for mediaId: UUID, kind: PromptKind) async -> UIImage? {
        if let hit = cached(mediaId) { return hit }
        if unavailable.contains(mediaId) { return nil }

        let task: Task<Data?, Never>
        if let existing = inFlight[mediaId] {
            task = existing
        } else {
            let api = self.api
            let staging = self.staging
            task = Task { await Self.load(mediaId: mediaId, kind: kind, api: api, staging: staging) }
            inFlight[mediaId] = task
        }

        let data = await task.value
        inFlight[mediaId] = nil

        guard let data, let image = UIImage(data: data) else {
            unavailable.insert(mediaId)
            return nil
        }
        memory.setObject(image, forKey: mediaId as NSUUID)
        return image
    }

    #endif

    /// Forget what could not be fetched. Pull-to-refresh means "try again", including for the
    /// photo that failed while the phone was in a lift.
    func retryFailures() {
        unavailable.removeAll()
    }

    // MARK: Off the main actor

    /// Disk first, then storage. `nonisolated` on purpose: every step here is file or network
    /// work, and none of it belongs on the actor that is drawing the scroll.
    private nonisolated static func load(
        mediaId: UUID,
        kind: PromptKind,
        api: APIClient,
        staging: StagingStore
    ) async -> Data? {
        let local = staging.thumbnailURL(for: mediaId)
        if let data = try? Data(contentsOf: local, options: .mappedIfSafe), !data.isEmpty {
            return data
        }

        // Video and audio stop here. See the type comment — pulling a whole video to draw a
        // 56pt square is not a trade worth making on someone's cellular plan.
        guard kind == .photo else { return nil }

        guard let signed = try? await api.mediaDownloadURL(mediaId: mediaId),
              let url = URL(string: signed),
              let (bytes, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let thumbnail = try? ImagePipeline.makeThumbnail(data: bytes)
        else { return nil }

        // Written where the composer writes its own, so there is one thumbnail cache rather
        // than two, and the staging sweep's rules apply to both — including deleting it when
        // its entry goes away.
        //
        // Best effort, and the empty catch is the point: the bytes are already in hand and
        // about to be drawn. A cache that cannot be written costs one more fetch the next time
        // this photo scrolls past — it does not cost the picture, so it must not fail the load.
        do { try staging.stageThumbnail(thumbnail, for: mediaId) } catch {}
        return thumbnail
    }
}

// MARK: - Environment

private struct ThumbnailStoreKey: EnvironmentKey {
    static let defaultValue: ThumbnailStore? = nil
}

extension EnvironmentValues {
    /// Passed through the environment rather than down four initialisers: an `EntryCard` deep
    /// inside a Moments carousel needs the same cache the timeline is filling.
    var thumbnails: ThumbnailStore? {
        get { self[ThumbnailStoreKey.self] }
        set { self[ThumbnailStoreKey.self] = newValue }
    }
}
