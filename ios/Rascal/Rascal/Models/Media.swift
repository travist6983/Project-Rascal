import Foundation
import SwiftData

/// A file attached to an entry, mirroring the `media` table in `docs/data-model.md`.
///
/// One row per file. `POST /media/upload-url` takes a single filename and returns a single
/// `media_id`; there is no batch shape in the contract, so three photos is three rows and
/// three calls. Inventing a batch endpoint would be a schema change.
@Model
final class Media {
    /// Client-generated alongside the entry, so the staged file has a name before any request.
    @Attribute(.unique) var id: UUID

    var entryId: UUID
    /// `photo` · `video` · `audio`. Stored as text for the same reason the server uses
    /// `text` + CHECK: a new kind must not require a migration.
    var kind: String

    // MARK: Local state

    /// Filename extension of the staged original, so its path is reconstructable from disk
    /// state alone after a force quit.
    var stagedExtension: String?
    /// Set once a thumbnail has been generated and written. The staged original is not
    /// deletable until this is true.
    var hasThumbnail: Bool

    var byteCount: Int
    var contentType: String

    /// EXIF `DateTimeOriginal` where the file had one. Sent to `complete` as `captured_at`.
    var capturedAt: Date?
    var durationSeconds: Int?

    // MARK: Upload state

    /// `staged` · `uploading` · `uploaded` · `complete` · `failed`.
    ///
    /// `uploaded` and `complete` are deliberately distinct: the bytes can be in storage while
    /// `POST /media/{id}/complete` has not yet succeeded, and until it has, the server does not
    /// know the object is there. Collapsing them loses exactly the case the retry exists for.
    var uploadState: String

    var s3Key: String?
    /// The server's thumbnail key. **Null on every row today** — that pipeline was cut from P0
    /// — so the timeline derives its own from the original. Stored anyway, because the day it
    /// stops being null is the day the client should stop downloading full-size photos.
    var thumbKey: String?
    /// From the upload-url response. Unused on the single-PUT path — it is null there — but
    /// stored so the multipart phase reads the server's number rather than guessing 8MB.
    var chunkBytes: Int?

    // MARK: Derived — written back from the phone, owned by the server afterwards

    /// On-device transcription, persisted through `PATCH /media/{id}/derived`. Cached here so
    /// a voice entry reads as text offline. The server never regenerates it.
    var transcript: String?
    var caption: String?

    /// Where the derived write is in its own lifecycle: `none` · `queued` · `pending` ·
    /// `synced` · `failed`. Stored as text for the same reason every other constrained value
    /// is — a new state must not require a migration.
    ///
    /// **Deliberately separate from `uploadState`.** The bytes and the words are two different
    /// journeys to the server that fail independently: a row can be `complete` on the upload
    /// leg and still be carrying words the server has never seen. Collapsing them would lose
    /// exactly the case the pull-conflict rule exists to protect.
    ///
    /// The `= "none"` is load bearing for the same reason `bytesSent`'s `= 0` is — see the note
    /// there. Migration rewrites existing rows and never calls `init`.
    var transcriptState: String = TranscriptSync.none.rawValue

    /// Attempts spent on whichever leg is outstanding — the inference, or the push. One counter
    /// because only one of the two can be outstanding at a time.
    var transcriptAttemptCount: Int = 0
    /// When the next attempt becomes eligible; nil once the cap is spent. On the row rather than
    /// in memory, so backoff survives a relaunch.
    var transcriptNextAttemptAt: Date?
    /// Why the last attempt did not land, for the backlog row. Never surfaced as an error
    /// anywhere a parent has not asked to look.
    var transcriptFailure: String?
    /// The locale the transcript was actually produced in, which is **not** always the device's
    /// — see `TranscriptionLocale`. Recorded so a fallback is a fact on the row rather than a
    /// guess later.
    var transcriptLocaleIdentifier: String?
    /// Returned by storage on a successful PUT and required by `complete`.
    var etag: String?

    /// Bytes the background session reports as sent. Written from the delegate as they
    /// arrive, so the ring measures real progress rather than animating a guess. Persisted
    /// because a relaunch mid-upload should resume the ring where it was, not at zero.
    ///
    /// **The `= 0` is load-bearing.** A non-optional property added to an existing `@Model`
    /// without a declaration default cannot be inferred by SwiftData's lightweight migration,
    /// and the store fails to open with "missing attribute values on mandatory destination
    /// attribute". Setting it in `init` is not enough — migration never runs `init`, it
    /// rewrites rows that already exist. This shipped without one and bricked the app on a
    /// device that had the previous build's store.
    var bytesSent: Int = 0

    var attemptCount: Int
    /// When the next retry becomes eligible. Backoff lives on the row, not in memory, so it
    /// survives a relaunch.
    var nextAttemptAt: Date?

    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        entryId: UUID,
        kind: String,
        contentType: String,
        byteCount: Int,
        stagedExtension: String? = nil,
        capturedAt: Date? = nil,
        durationSeconds: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.entryId = entryId
        self.kind = kind
        self.contentType = contentType
        self.byteCount = byteCount
        self.stagedExtension = stagedExtension
        self.capturedAt = capturedAt
        self.durationSeconds = durationSeconds
        self.hasThumbnail = false
        self.uploadState = MediaUploadState.staged.rawValue
        self.bytesSent = 0
        self.attemptCount = 0
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var state: MediaUploadState {
        get { MediaUploadState(rawValue: uploadState) }
        set {
            uploadState = newValue.rawValue
            updatedAt = Date()
        }
    }

    var mediaKind: PromptKind { PromptKind(rawValue: kind) }

    /// The server has acknowledged the object. Only then is the local original expendable —
    /// and only once a thumbnail exists to render in its place.
    var isComplete: Bool { state == .complete }

    /// **The staging sweep's rule, in one place.**
    ///
    /// Both conditions, never a timer. A timer is a second source of truth about when a file is
    /// disposable and the two will disagree eventually. `complete` alone is not enough either:
    /// deleting then means the first timeline render refetches every photo just uploaded.
    var stagedOriginalIsDisposable: Bool {
        isComplete && hasThumbnail
    }

    /// Outstanding work, for the one sweep that owns retries.
    var needsUpload: Bool {
        deletedAt == nil && !isComplete && state != .uploading
    }

    // MARK: Rows the server told us about

    /// A media row this phone never staged, cached from a timeline or detail response.
    ///
    /// **Only ever built from a `complete` summary.** A row the server still calls pending has
    /// no bytes anywhere this device can reach, and creating it locally would put it in the
    /// upload sweep — which would look for a staged file that was never here, find nothing, and
    /// mark a perfectly healthy upload on someone else's phone as failed.
    ///
    /// `contentType` is inferred from `kind` rather than carried on the wire, because
    /// `MediaSummary` does not include it. It is only ever read on the upload path, which a
    /// complete row can no longer take.
    static func fromServer(_ summary: MediaSummaryResponse, entryId: UUID) -> Media? {
        guard summary.isComplete else { return nil }
        let media = Media(
            id: summary.id,
            entryId: entryId,
            kind: summary.kind,
            contentType: summary.mediaKind.archiveContentType,
            byteCount: summary.bytes,
            capturedAt: summary.capturedAt,
            durationSeconds: summary.durationSeconds
        )
        media.applyServerSummary(summary)
        return media
    }

    /// Fold a summary onto an existing row.
    ///
    /// Upload state is written **only forward, to complete**. A row this phone is mid-upload on
    /// must not be dragged back to `staged` by a list response that raced the acknowledgement.
    func applyServerSummary(_ summary: MediaSummaryResponse) {
        s3Key = summary.s3Key
        thumbKey = summary.thumbKey
        durationSeconds = summary.durationSeconds ?? durationSeconds
        capturedAt = summary.capturedAt ?? capturedAt
        // **The pending-local rule, applied to a transcript.** Every path that folds server
        // truth onto a media row funnels through here — `/sync`, `GET /entries`, and
        // `GET /entries/{id}` — so the protection lives here rather than in one of the three.
        // That matters more than it looks: `syncPullEnabled` ships false, so the pull is the
        // path that usually is *not* running, and the timeline's refetch is the one that is.
        if !hasUnpushedTranscript {
            // Detail carries these; a list row does not, and must not blank what detail cached.
            transcript = summary.transcript ?? transcript
        }
        caption = summary.caption ?? caption
        if summary.isComplete, !isComplete {
            state = .complete
            attemptCount = 0
            nextAttemptAt = nil
        }
    }

    // MARK: Transcription

    var transcriptSync: TranscriptSync {
        get { TranscriptSync(rawValue: transcriptState) }
        set { transcriptState = newValue.rawValue }
    }

    /// Words this phone produced that the server has not acknowledged.
    ///
    /// **`failed` counts here, and that is the opposite of the upload path's rule** — the
    /// asymmetry is the whole point. A media row past its upload cap has its bytes safe in
    /// storage and the server's copy is the better of the two, so `hasUnpushedChanges(_ media:)`
    /// in `SyncEngine` excludes it. A transcript past its push cap exists **only here**: the
    /// server has never seen it, nothing else holds it, and it cost a battery to produce.
    /// Dropping the protection at the cap would let the next pull erase the one copy.
    var hasUnpushedTranscript: Bool {
        guard transcript != nil else { return false }
        return transcriptSync == .pending || transcriptSync == .failed
    }

    /// Words the archive is missing, on a row that could supply them.
    ///
    /// `queued` is included and `none` is not: the backlog is opt-in and manual, so a row nobody
    /// has asked about stays untouched. See `TranscriptionQueue.backlog`.
    var awaitsTranscription: Bool {
        deletedAt == nil && isComplete && transcript == nil && transcriptSync == .queued
    }

    /// The one place a finished transcript is written onto a row.
    ///
    /// Local first, then the push — so a crash between the two loses nothing and the retry is
    /// idempotent. The state it lands in is what protects it from the next pull.
    func recordTranscript(_ text: String, locale: TranscriptionLocale) {
        transcript = text
        transcriptLocaleIdentifier = locale.locale.identifier
        transcriptSync = .pending
        transcriptAttemptCount = 0
        transcriptNextAttemptAt = nil
        transcriptFailure = nil
        updatedAt = Date()
    }

    /// One failed attempt on whichever leg is outstanding, with the same backoff the upload uses.
    ///
    /// Past the cap the row goes to `failed` and stops being retried automatically — but a
    /// transcript already written stays protected, because `hasUnpushedTranscript` includes
    /// `failed`. A backlog run is what clears it, because someone asked.
    func recordTranscriptFailure(_ reason: String, now: Date = Date(), jitter: Double = .random(in: 0.5...1.5)) {
        transcriptAttemptCount += 1
        transcriptFailure = reason
        if let next = UploadBackoff.nextAttempt(after: transcriptAttemptCount, now: now, jitter: jitter) {
            transcriptNextAttemptAt = next
        } else {
            transcriptNextAttemptAt = nil
            transcriptSync = .failed
        }
    }

    /// Someone pressed a button. Clear the backoff and put the row back in the queue it belongs
    /// in — the push queue if there are words to push, the inference queue if there are not.
    func resetTranscriptForManualRun() {
        transcriptAttemptCount = 0
        transcriptNextAttemptAt = nil
        transcriptFailure = nil
        if transcriptSync == .failed {
            transcriptSync = transcript == nil ? .queued : .pending
        }
    }
}

/// Where a media row's derived write has got to.
///
/// Deliberately its own ladder rather than a second reading of `uploadState`. The bytes and the
/// words reach the server by different routes and fail independently.
nonisolated enum TranscriptSync: RawRepresentable, Equatable, Sendable {
    /// Nobody has asked. Every row in the pre-feature backlog sits here, and the automatic path
    /// never walks them — that is what keeps a first launch from becoming a battery event.
    case none
    /// Should be transcribed. Written **before** inference starts, so a kill mid-run resumes
    /// rather than losing the job.
    case queued
    /// Transcribed here, not yet pushed. The state the pull-conflict rule protects.
    case pending
    /// `PATCH /media/{id}/derived` succeeded. The server owns it now.
    case synced
    /// Past the retry cap. Surfaced in the backlog row, never as an error over the archive.
    case failed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "queued": self = .queued
        case "pending": self = .pending
        case "synced": self = .synced
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .none: "none"
        case .queued: "queued"
        case .pending: "pending"
        case .synced: "synced"
        case .failed: "failed"
        case .unknown(let raw): raw
        }
    }
}

extension PromptKind {
    /// What the archive stores for this kind. The decisions behind these are in
    /// `ImagePipeline` (JPEG, not HEIC) and `VideoPipeline` (H.264 in MP4).
    var archiveContentType: String {
        switch self {
        case .photo: "image/jpeg"
        case .video: "video/mp4"
        case .audio: "audio/m4a"
        default: "application/octet-stream"
        }
    }
}

nonisolated enum MediaUploadState: RawRepresentable, Equatable, Sendable {
    /// On disk, nothing sent.
    case staged
    /// A background task is carrying the bytes.
    case uploading
    /// Storage has them; `complete` has not succeeded yet.
    case uploaded
    /// The server knows. Terminal.
    case complete
    /// Past the retry cap. Surfaced and manually retryable — never silently dropped.
    case failed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "staged": self = .staged
        case "uploading": self = .uploading
        case "uploaded": self = .uploaded
        case "complete": self = .complete
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .staged: "staged"
        case .uploading: "uploading"
        case .uploaded: "uploaded"
        case .complete: "complete"
        case .failed: "failed"
        case .unknown(let raw): raw
        }
    }
}
