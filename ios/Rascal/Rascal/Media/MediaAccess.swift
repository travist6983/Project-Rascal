import AVFoundation
import Foundation

/// Getting at the bytes themselves, for a screen that shows one entry rather than five hundred.
///
/// `ThumbnailStore` is a bounded cache for list rows. This is the other half: full-size pixels
/// for the fullscreen viewer, and a URL AVPlayer can open for a video or a voice note. Neither is
/// cached to disk — a full-size copy of every photo ever opened would grow without bound, and the
/// thumbnail already covers the case that repeats.
///
/// **The signed URL is minted per use and never stored.** It outlives its signature, and a stored
/// one fails later in a way that reads like the archive lost the file. Cache the bytes, refetch
/// the URL.
nonisolated enum MediaAccess {

    /// Full-size bytes: the staged original if this phone still has it, otherwise storage.
    ///
    /// The local copy is checked first because it is free and identical — the staging sweep only
    /// removes an original once the server has acknowledged it, so a file that is still here is
    /// the same file that is there.
    static func fullImageData(mediaId: UUID, localFile: URL?, api: APIClient) async -> Data? {
        if let localFile, let data = try? Data(contentsOf: localFile, options: .mappedIfSafe) {
            return data
        }
        guard let url = await signedURL(mediaId: mediaId, api: api),
              let (bytes, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return bytes
    }

    /// Something `AVPlayer` can open — a file on disk, or a short-lived URL into storage.
    ///
    /// Streaming rather than downloading is the whole reason this returns a URL instead of
    /// bytes: a minute of 1080p is about seventy megabytes, and pulling all of it into memory
    /// before the first frame plays is how a detail screen gets killed.
    static func playbackURL(mediaId: UUID, localFile: URL?, api: APIClient) async -> URL? {
        if let localFile, FileManager.default.fileExists(atPath: localFile.path) {
            return localFile
        }
        return await signedURL(mediaId: mediaId, api: api)
    }

    /// A poster frame for a video this phone did not record.
    ///
    /// The timeline will not do this — pulling a hundred megabytes to draw a 56pt square is not
    /// a trade worth making on someone's cellular plan. **Entry Detail is different**: the parent
    /// has opened this one entry and the next thing they will do is press play, which downloads
    /// the video regardless. So the cost is borrowed rather than added, and it buys a frame of
    /// their child instead of a tinted rectangle.
    ///
    /// `AVAssetImageGenerator` reads over ranged HTTP, so it takes the first moments of the file
    /// rather than the whole thing. The result is written to the same staging cache the composer
    /// uses, so it happens once per video, ever — and the timeline picks it up from disk after.
    static func posterFrame(
        mediaId: UUID,
        localFile: URL?,
        api: APIClient,
        staging: StagingStore
    ) async -> Data? {
        guard let url = await playbackURL(mediaId: mediaId, localFile: localFile, api: api) else {
            return nil
        }
        // `try?` over a throwing function that already returns `Data?` flattens to one optional.
        guard let data = try? await VideoPipeline.posterFrame(for: AVURLAsset(url: url)) else {
            return nil
        }

        do { try staging.stageThumbnail(data, for: mediaId) } catch {}
        return data
    }

    /// `409 upload_incomplete` is the one failure worth naming: the row exists and its bytes do
    /// not, which is an unfinished upload rather than a lost file. Everything else is nil, and
    /// the view says so in its own words.
    private static func signedURL(mediaId: UUID, api: APIClient) async -> URL? {
        guard let raw = try? await api.mediaDownloadURL(mediaId: mediaId) else { return nil }
        return URL(string: raw)
    }
}
