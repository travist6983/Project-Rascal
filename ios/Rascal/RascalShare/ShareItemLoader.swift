import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns the share sheet's item providers into staged files in the App Group container.
///
/// **Everything expensive about a share happens here, and none of it is expensive.** The bytes are
/// copied by the kernel, the capture date is read out of metadata, and the preview is a 400px
/// thumbnail ImageIO produces without ever decoding the full image. Nothing is converted,
/// transcoded or thumbnailed to archive quality — the app does all of that on the way in, where
/// there is no memory ceiling and no clock counting down to a process kill.
@MainActor
enum ShareItemLoader {

    /// One staged file, plus the little the extension's own UI needs to draw it.
    ///
    /// The preview and the duration are held in memory for this screen only and are deliberately
    /// **not** written into the record: the app re-derives both properly when it converts, and a
    /// thumbnail written here would be a second, worse copy of something `ImagePipeline` already
    /// owns.
    struct Loaded: Identifiable, Sendable {
        let item: PendingShare.Item
        /// A small JPEG for the tile. Nil for video, which is drawn as a glyph — see
        /// `SharePreviewRow`.
        let preview: Data?
        let durationSeconds: Int?

        var id: UUID { item.id }
    }

    /// Stage everything the share carried, in the order it arrived.
    ///
    /// Sequential rather than concurrent, on purpose. Ten videos copied in parallel is ten open
    /// file handles and ten sets of buffers in a process the system is already willing to kill,
    /// and the copies are I/O-bound anyway — running them at once would not make the screen appear
    /// sooner.
    static func load(_ providers: [NSItemProvider], into inbox: ShareInbox) async -> [Loaded] {
        var loaded: [Loaded] = []
        for provider in providers {
            if let one = await stage(provider, into: inbox) { loaded.append(one) }
        }
        return loaded
    }

    /// The type this provider should be staged as, or nil to refuse it.
    ///
    /// Registered identifiers are scanned in order and the first that resolves wins: Photos lists
    /// the primary representation first, and a Live Photo — which registers a still image
    /// alongside the live-photo type — therefore stages as the still, which is the right answer
    /// and the only one the archive has a shape for.
    ///
    /// Separate from `stage` so a provider carrying nothing this app accepts is refused before a
    /// single byte is copied.
    static func acceptedType(of provider: NSItemProvider) -> (identifier: String, kind: ShareMediaKind)? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier), let kind = ShareMediaKind.resolve(type) else { continue }
            return (identifier, kind)
        }
        return nil
    }

    private static func stage(_ provider: NSItemProvider, into inbox: ShareInbox) async -> Loaded? {
        guard let accepted = acceptedType(of: provider) else { return nil }

        let mediaId = UUID()
        guard let staged = await copyIn(
            provider,
            typeIdentifier: accepted.identifier,
            mediaId: mediaId,
            into: inbox
        ) else { return nil }

        let item = PendingShare.Item(
            id: mediaId,
            filename: staged.filename,
            kind: accepted.kind,
            byteCount: staged.byteCount,
            capturedAt: nil
        )
        guard let url = inbox.mediaURL(for: item) else { return nil }

        switch accepted.kind {
        case .photo:
            return Loaded(
                item: PendingShare.Item(
                    id: item.id,
                    filename: item.filename,
                    kind: item.kind,
                    byteCount: item.byteCount,
                    // Read off the staged copy rather than the source, which is already gone.
                    // `ImagePipeline` is shared with the app rather than reimplemented, so a
                    // shared photo's date is derived by exactly the code a picked one's is.
                    capturedAt: ImagePipeline.exifDate(fileAt: url)
                ),
                preview: try? ImagePipeline.makeThumbnail(fileAt: url),
                durationSeconds: nil
            )

        case .video:
            let (created, duration) = await videoMetadata(at: url)
            return Loaded(
                item: PendingShare.Item(
                    id: item.id,
                    filename: item.filename,
                    kind: item.kind,
                    byteCount: item.byteCount,
                    capturedAt: created
                ),
                // **No poster frame.** Extracting one means `AVAssetImageGenerator` on a file
                // that may be a 4K minute, inside the process with the memory ceiling, to draw
                // an 84pt tile. The glyph tile `MediaPreviewRow` already uses for voice notes is
                // the existing answer to "this media has nothing to draw", and it costs nothing.
                preview: nil,
                durationSeconds: duration
            )
        }
    }

    /// Copy the bytes in.
    ///
    /// **`loadFileRepresentation`, never `loadDataRepresentation`.** The data form reads the whole
    /// file into memory — hundreds of megabytes for a 4K minute — which is the single easiest way
    /// to get a share extension killed. The file form hands over a URL and
    /// `ShareInbox.stage(copyingFrom:)` lets the kernel do the copying.
    ///
    /// **The copy happens inside the completion handler**, because the URL is deleted the moment
    /// that handler returns. Resuming the continuation first and copying afterwards would be a
    /// race that passes on a small photo and loses a large video.
    private static func copyIn(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        mediaId: UUID,
        into inbox: ShareInbox
    ) async -> ShareInbox.Staged? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let staged = try? inbox.stage(
                    copyingFrom: url,
                    as: mediaId,
                    ext: url.pathExtension
                )
                continuation.resume(returning: staged)
            }
        }
    }

    /// Creation date and duration, both metadata reads. No frame is decoded and no track is
    /// opened, so this stays flat whatever the file weighs.
    private static func videoMetadata(at url: URL) async -> (created: Date?, duration: Int?) {
        let asset = AVURLAsset(url: url)
        let created = try? await asset.load(.creationDate)?.load(.dateValue)
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
        guard let seconds, seconds.isFinite, seconds > 0 else { return (created, nil) }
        return (created, Int(seconds.rounded()))
    }
}
