import AVFoundation
import Foundation

#if canImport(Photos)
import Photos
#endif

/// Turns a captured or picked video into what the archive should hold.
///
/// The decision, recorded in `docs/decisions.md`: **1080p H.264/AAC in MP4**, with an in-app
/// capture's original written back to the camera roll.
///
/// The format reasoning is the same one that made photos JPEG rather than HEIC — the archive
/// has to open in 2040 in something that isn't Apple, and H.264 in MP4 is the most universally
/// decodable video there is. The size reasoning is arithmetic: roughly 70MB a minute against
/// 375MB for 4K, which over eighteen years and two children is about 130GB against 650GB.
///
/// Transcoding is lossy and irreversible, so nothing is destroyed to get there. A video taken
/// in-app exists nowhere else unless it is saved, so it is saved.
enum VideoPipeline {

    struct Processed {
        /// The transcoded file, already in staging.
        let url: URL
        let byteCount: Int
        let durationSeconds: Int
        /// First frame, for the timeline. `thumb_key` is null server-side and generation was cut
        /// from P0, so this local cache is what makes a video render as anything at all.
        let posterFrame: Data?
        /// EXIF-equivalent creation date, where the source carried one.
        let capturedAt: Date?

        var contentType: String { "video/mp4" }
        var fileExtension: String { "mp4" }
    }

    enum Failure: Error, Equatable {
        case unreadable
        case exportUnsupported
        case exportFailed(String)
    }

    /// 1080p. `AVAssetExportPreset1920x1080` downscales anything larger and leaves anything
    /// smaller alone — it never upscales, so a 720p clip stays 720p rather than being inflated.
    static let preset = AVAssetExportPreset1920x1080

    static func process(fileAt source: URL, into staging: StagingStore, as mediaId: UUID) async throws -> Processed {
        let asset = AVURLAsset(url: source)

        guard try await asset.load(.isExportable) else { throw Failure.unreadable }

        let destination = staging.originalURL(for: mediaId, ext: "mp4")
        try? FileManager.default.removeItem(at: destination)

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure.exportUnsupported
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        // Streaming-friendly: the moov atom moves to the front, so a player can start before
        // the whole file arrives. Matters for anything watched from storage later.
        session.shouldOptimizeForNetworkUse = true

        try await session.export(to: destination, as: .mp4)

        let duration = try await asset.load(.duration)
        let created = try? await asset.load(.creationDate)?.load(.dateValue)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0

        return Processed(
            url: destination,
            // `bytes` already coalesced to 0 above; a second `?? 0` here was dead and the
            // compiler said so.
            byteCount: bytes,
            durationSeconds: Int(CMTimeGetSeconds(duration).rounded()),
            posterFrame: try? await posterFrame(for: asset),
            capturedAt: created
        )
    }

    /// A frame from just after the start rather than exactly zero — the first frame of a
    /// handheld video is very often a blur or a lens cap, and the poster is what someone
    /// scrolls past in a timeline.
    static func posterFrame(for asset: AVAsset) async throws -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: ImagePipeline.thumbnailMaxPixels,
                                       height: ImagePipeline.thumbnailMaxPixels)

        let duration = try await asset.load(.duration)
        let at = CMTimeMinimum(CMTime(seconds: 0.5, preferredTimescale: 600), duration)
        let (image, _) = try await generator.image(at: at)

        return try? ImagePipeline.encodeJPEGForPoster(image)
    }

    /// Keep the original. The transcode is lossy and one-way, and a capture taken in-app is
    /// not in the photo library unless it is put there — so "we shrank it to save space" would
    /// otherwise mean "we deleted your 4K".
    ///
    /// Best-effort by design: a refusal to grant library access must not fail the capture, and
    /// the archive copy is already safe by this point.
    static func preserveOriginal(at url: URL) async {
        #if canImport(Photos)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
        #endif
    }
}
