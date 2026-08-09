import Foundation
import SwiftData

/// One part of a multipart upload.
///
/// A 1080p minute is roughly 70MB, which is past the server's 15MB threshold, so video is
/// always multipart. Parts get their own rows for the same reason `Media` has one: a force quit
/// mid-upload must be resumable from disk state alone, and "which of the five parts already
/// landed" is exactly the state that would otherwise be lost.
///
/// Two facts the server owns and this must not second-guess, both established by uploading a
/// real 40MB object to Tigris before any of this was written:
///
/// - **The split size is `chunk_bytes` from the upload-url response.** The server computed the
///   part count from it, so a client that picks its own size produces the wrong number of parts
///   and completion fails.
/// - **The ETag is required.** Unlike the single-PUT path, where the server ignores it,
///   `complete` needs an ETag for every part — so a part with no ETag is not finished, however
///   successful its PUT looked.
@Model
final class MediaPart {
    @Attribute(.unique) var id: UUID

    var mediaId: UUID
    /// 1-based, and the order `complete` expects them sorted in.
    var partNumber: Int

    /// Byte range of the staged file this part carries. Stored rather than recomputed so a
    /// resumed upload cannot disagree with the plan the server signed.
    var offset: Int
    var length: Int

    /// The presigned destination. Expires — `expiresAt` says when, and a part whose URL has
    /// lapsed needs a fresh plan rather than a retry.
    var uploadURL: String
    var expiresAt: Date?

    /// Returned by storage on a successful PUT. Its presence *is* the definition of done for
    /// a part: without it, `complete` cannot be called.
    var etag: String?

    var bytesSent: Int = 0
    var attemptCount: Int = 0
    var nextAttemptAt: Date?

    init(
        id: UUID = UUID(),
        mediaId: UUID,
        partNumber: Int,
        offset: Int,
        length: Int,
        uploadURL: String,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.mediaId = mediaId
        self.partNumber = partNumber
        self.offset = offset
        self.length = length
        self.uploadURL = uploadURL
        self.expiresAt = expiresAt
    }

    /// A part is done when storage has acknowledged it with an ETag, not when its PUT returned.
    var isUploaded: Bool { etag?.isEmpty == false }

    var fraction: Double {
        isUploaded ? 1 : (length > 0 ? min(1, Double(bytesSent) / Double(length)) : 0)
    }

    /// The presigned URL has lapsed and the part needs re-planning, not retrying. Signing is
    /// offline and cheap; retrying a dead URL just burns attempts against a guaranteed 403.
    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}

extension Media {
    /// Multipart when the server said so — which it signals by returning parts rather than a
    /// single `upload_url`. Never inferred from file size on this side.
    var isMultipart: Bool { chunkBytes != nil && chunkBytes! > 0 }
}
