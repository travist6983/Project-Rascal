import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A photo the parent has chosen but not yet saved.
///
/// The bytes are already on disk — staging happens the moment a file is picked, before the
/// entry exists — because PHPicker's URLs are temporary and the composer may sit open for
/// minutes while someone types. Only the SwiftData rows wait for save.
///
/// `id` is the eventual `media_id`, generated here so the staged filename is already right and
/// nothing has to be renamed later.
struct MediaDraft: Identifiable, Equatable {
    let id: UUID
    let stagedURL: URL
    let fileExtension: String
    let byteCount: Int
    let contentType: String
    /// EXIF `DateTimeOriginal`, or a video's creation date, where the source had one.
    let capturedAt: Date?
    /// Held in memory for the preview only; also written to staging for the timeline cache.
    /// For a video this is the poster frame.
    let thumbnail: Data
    /// `photo` or `video`. Drives the badge on the preview tile and the `kind` sent to the
    /// server, which decides single-PUT versus multipart.
    var kind: String = "photo"
    /// Seconds, for a video. Sent to `complete`.
    var durationSeconds: Int?

    var isVideo: Bool { kind == "video" }

    var image: Image? {
        #if canImport(UIKit)
        UIImage(data: thumbnail).map { Image(uiImage: $0) }
        #else
        nil
        #endif
    }
}

/// Turns a picked or captured file into a staged draft.
///
/// One place, so the camera and the library cannot diverge — a photo taken in-app and one
/// picked from the roll must be processed identically or the archive ends up with two
/// different kinds of JPEG.
enum MediaDraftBuilder {

    static func make(from data: Data, store: StagingStore) throws -> MediaDraft {
        let processed = try ImagePipeline.process(data: data)
        return try stage(processed, store: store)
    }

    static func make(fileAt url: URL, store: StagingStore) throws -> MediaDraft {
        let processed = try ImagePipeline.process(fileAt: url)
        return try stage(processed, store: store)
    }

    /// A video, transcoded to 1080p H.264 on the way in. The original is preserved to the
    /// camera roll by the caller — this only decides what the archive holds.
    static func makeVideo(fileAt url: URL, store: StagingStore) async throws -> MediaDraft {
        let id = UUID()
        let processed = try await VideoPipeline.process(fileAt: url, into: store, as: id)
        if let poster = processed.posterFrame {
            try? store.stageThumbnail(poster, for: id)
        }
        return MediaDraft(
            id: id,
            stagedURL: processed.url,
            fileExtension: processed.fileExtension,
            byteCount: processed.byteCount,
            contentType: processed.contentType,
            capturedAt: processed.capturedAt,
            thumbnail: processed.posterFrame ?? Data(),
            kind: "video",
            durationSeconds: processed.durationSeconds
        )
    }

    private static func stage(
        _ processed: ImagePipeline.Processed,
        store: StagingStore
    ) throws -> MediaDraft {
        let id = UUID()
        // The converted JPEG is what is staged, not the original: the archive holds the
        // upright JPEG, so that is the thing whose bytes must survive a force quit.
        let staged = try store.stage(data: processed.data, as: id, ext: processed.fileExtension)
        try store.stageThumbnail(processed.thumbnail, for: id)

        return MediaDraft(
            id: id,
            stagedURL: staged,
            fileExtension: processed.fileExtension,
            byteCount: processed.data.count,
            contentType: processed.contentType,
            capturedAt: processed.capturedAt,
            thumbnail: processed.thumbnail
        )
    }

    /// The entry date a set of drafts implies.
    ///
    /// The **earliest** EXIF date among them, not the latest and not now. Picking three photos
    /// from an afternoon should file the entry on that afternoon, and if one of them has no
    /// date it should not drag the entry forward to today.
    static func suggestedOccurredAt(for drafts: [MediaDraft], now: Date = Date()) -> Date {
        let dates = drafts.compactMap(\.capturedAt)
        return dates.min() ?? now
    }
}

/// A video pulled out of `PhotosPicker` as a file rather than as bytes.
///
/// `loadTransferable(type: Data.self)` would work and would also read an entire video into
/// memory — hundreds of megabytes for a 4K minute. This copies it to a temporary file instead,
/// which is what every downstream step wants anyway.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "picked-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
