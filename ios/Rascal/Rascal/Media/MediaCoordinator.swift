import Foundation
import SwiftData

/// Owns the order of the three-step upload, and the retry that each step needs separately.
///
/// **Entry first, then media.** `POST /entries` creates the row, `POST /media/upload-url`
/// needs that `entry_id`, then the PUT, then `complete`. An entry whose media is still
/// uploading is a valid, complete, viewable entry — nothing waits on bytes.
///
/// The three legs fail independently and are retried independently. In particular a PUT that
/// succeeded while `complete` failed must **not** re-upload: the bytes are already in storage,
/// and sending them again wastes a parent's cellular data to reach the same state.
@MainActor
@Observable
final class MediaCoordinator {

    /// **Global on purpose, and it has to be. Do not "fix" this, and do not make a second one.**
    ///
    /// The upload delegate reaches back through this to run `POST /media/{id}/complete` once
    /// storage has the bytes. That call needs an authenticated `APIClient`, and the delegate
    /// has no way to be handed one:
    ///
    /// - A background `URLSession` delegate is invoked by the system, on a callback path the
    ///   app does not construct. There is no injection point in it.
    /// - Worse, the system may create the *process itself* purely to deliver those callbacks
    ///   after a force quit or a suspension. `RascalApp`, `RootView`, and every value they
    ///   would have passed down do not exist yet when the delegate runs. There is nothing to
    ///   inject *from*.
    ///
    /// So something must be reachable without an owner, and this is it. Dependency injection
    /// is not an option that was available and rejected; it is not on the table.
    ///
    /// **Exactly one, for the process lifetime.** Two coordinators means two sweeps racing over
    /// the same rows and two `complete` calls for one upload. The uploader's single-session
    /// rule and this are the same constraint seen from two ends.
    ///
    /// What would remove it: the delegate enqueueing work rather than performing it — writing
    /// an "needs completing" marker to SwiftData and letting the next foreground sweep make the
    /// call. That trades this global for a delay before the server learns the object landed,
    /// which is worse for the parent, so it was not taken.
    static var shared: MediaCoordinator?

    /// **How many times the server has refused a media upload for membership this session**
    /// (phase 147).
    ///
    /// A counter rather than a `Bool`, and observed rather than stored, for the reasons
    /// `SubscriptionCenter.householdRevision` gives: a bump is *an event*, and a `Bool` that is
    /// already `true` reports the second refusal as nothing at all. It says one true thing — the
    /// server just refused — and holds no opinion about the tier. The screen that answers it goes
    /// and re-reads the one route that knows.
    ///
    /// **Nothing is persisted, and there is no column for this.** `SyncUploadsModel` records that
    /// `Media` carries no upload-failure reason and that inventing one is a schema change belonging
    /// to its own phase; this phase does not invent one. The consequence is that the sentence is a
    /// session's, not a row's: relaunching loses it, and the row reads as an ordinary stopped
    /// upload — which is what it is.
    private(set) var membershipRefusals = 0

    private let api: APIClient
    private let store: StagingStore
    private let uploader: MediaUploader
    private var sweeping = false

    /// Words, once the bytes have landed.
    ///
    /// Assigned after construction rather than injected, because the queue needs a `ModelContext`
    /// from the SwiftUI environment and this object is built before there is one — the same
    /// ordering that makes `MediaCoordinator.shared` necessary in the first place. Optional for
    /// the reason `EntrySync.media` is: the upload tests need no transcriber, and a nil one makes
    /// this file behave exactly as it did before transcription existed.
    ///
    /// **One direction only.** The queue does not hold this object back; it takes the `APIClient`
    /// directly. Two process-lifetime singletons pointing at each other is a retain cycle that
    /// nothing would ever notice and nobody could ever explain.
    var transcription: TranscriptionQueue?

    /// The uploader defaults inside the body rather than in the signature: a default argument
    /// is evaluated in a nonisolated context, and `MediaUploader.shared` is main-actor bound.
    init(api: APIClient, store: StagingStore = StagingStore(), uploader: MediaUploader? = nil) {
        self.api = api
        self.store = store
        self.uploader = uploader ?? .shared
    }

    private func context() -> ModelContext { ModelContext(LocalStore.shared) }

    // MARK: The three legs

    /// Ask the server where to put it, then hand the file to the background session.
    func beginUpload(mediaId: UUID) async {
        let context = context()
        guard let media = Self.media(id: mediaId, in: context),
              media.deletedAt == nil,
              media.state == .staged,
              let ext = media.stagedExtension
        else { return }

        let fileURL = store.originalURL(for: media.id, ext: ext)
        guard store.exists(fileURL) else {
            // The bytes are gone and were never uploaded. Nothing can recover this, and
            // pretending otherwise would leave a row retrying forever against no file.
            media.state = .failed
            try? context.save()
            return
        }

        do {
            let ticket = try await api.mediaUploadURL(
                mediaId: media.id,
                entryId: media.entryId,
                kind: media.kind,
                filename: fileURL.lastPathComponent,
                bytes: media.byteCount,
                contentType: media.contentType
            )
            media.s3Key = ticket.s3Key
            // Stored, not read. Null on the single-PUT path, which is normal — the multipart
            // phase is the first thing that will use it, and it must use the server's number
            // rather than assuming 8MB.
            media.chunkBytes = ticket.chunkBytes
            media.state = .uploading
            try? context.save()

            if let parts = ticket.parts, !parts.isEmpty, let chunk = ticket.chunkBytes {
                planParts(for: media, parts: parts, chunk: chunk, in: context)
                try? context.save()
                dispatchParts(media: media, file: fileURL, in: context)
                return
            }

            guard let destination = ticket.uploadURL.flatMap(URL.init(string:)) else {
                media.recordAttemptFailure()
                try? context.save()
                return
            }
            uploader.start(
                mediaId: media.id,
                from: fileURL,
                to: destination,
                contentType: media.contentType
            )
        } catch let error as APIError where error.code == .subscriptionRequired {
            // **Terminal at once, and not a retry** (phase 147). The household is not entitled to
            // add new media, and the server will answer identically on every attempt until that
            // changes — so spending the backoff schedule on it would be six requests over hours to
            // be told the same thing, and would leave the row reading *Waiting* the whole time.
            // The same shape as `finishUpload`'s `.notFound` branch, for the same reason: a refusal
            // a retry cannot move is a failure now rather than a failure later.
            //
            // **Nothing here is deleted and nothing is hidden.** The staged original stays on the
            // phone, the `Media` row stays, the `Entry` and every word in it are already saved and
            // sync normally — D3's operative test is that no existing entry becomes unreadable,
            // unexportable or unsearchable, and this touches none of that. If the household
            // becomes a member the row is retried by the same *Upload it* control that has always
            // been there, because `resetForManualRetry` puts a `failed` row back to `staged`.
            media.state = .failed
            media.nextAttemptAt = nil
            try? context.save()
            membershipRefusals &+= 1
        } catch {
            media.recordAttemptFailure()
            try? context.save()
        }
    }

    /// Record the server's plan. The byte ranges come from `chunk_bytes`, which the server used
    /// to compute the part count — a client that picks its own size produces the wrong number of
    /// parts and completion fails.
    private func planParts(for media: Media, parts: [UploadPart], chunk: Int, in context: ModelContext) {
        for existing in MediaUploader.parts(of: media.id, in: context) {
            context.delete(existing)
        }
        let expiry = Date().addingTimeInterval(3000)
        for part in parts.sorted(by: { $0.partNumber < $1.partNumber }) {
            let offset = (part.partNumber - 1) * chunk
            // The last part is short — the file rarely divides evenly, and sending a full chunk
            // from the end would read past EOF and upload padding.
            let length = min(chunk, max(0, media.byteCount - offset))
            context.insert(MediaPart(
                mediaId: media.id,
                partNumber: part.partNumber,
                offset: offset,
                length: length,
                uploadURL: part.uploadUrl,
                expiresAt: expiry
            ))
        }
    }

    /// Hand every outstanding part to the background session. Parts already carrying an ETag
    /// are skipped, which is what makes a resumed upload resume rather than restart.
    private func dispatchParts(media: Media, file: URL, in context: ModelContext) {
        for part in MediaUploader.parts(of: media.id, in: context) where !part.isUploaded {
            guard let url = URL(string: part.uploadURL), part.length > 0 else { continue }
            uploader.startPart(
                mediaId: media.id,
                partNumber: part.partNumber,
                sourceFile: file,
                offset: part.offset,
                length: part.length,
                to: url
            )
        }
    }

    /// Tell the server the object landed. Called by the upload delegate, and retried by the
    /// sweep independently of the PUT.
    func finishUpload(mediaId: UUID) async {
        let context = context()
        guard let media = Self.media(id: mediaId, in: context),
              media.deletedAt == nil,
              media.state == .uploaded
        else { return }

        // Multipart completion needs an ETag for every part, sorted — the server assembles in
        // the order it is given. Verified against Tigris with a real 40MB object before any of
        // this was written.
        let etags = MediaUploader.parts(of: media.id, in: context)
            .compactMap { part in part.etag.map { (part: part.partNumber, etag: $0) } }

        if media.isMultipart, etags.count != MediaUploader.parts(of: media.id, in: context).count {
            // A part is still outstanding. Completing now would assemble a truncated object,
            // which storage accepts and nobody notices until the video will not play.
            return
        }

        do {
            try await api.completeMedia(
                mediaId: media.id,
                etags: etags,
                capturedAt: media.capturedAt,
                durationSeconds: media.durationSeconds
            )
            media.state = .complete
            media.attemptCount = 0
            media.nextAttemptAt = nil
            try? context.save()
            // The server now has the row, which is the precondition
            // `PATCH /media/{id}/derived` needs — so this is the earliest honest moment to
            // consider transcribing it. **After the save**, so the queue's own context reads a
            // row that is genuinely complete rather than one this context has not written yet.
            //
            // Opportunistic and unawaited by anything a parent is looking at: nothing on Today,
            // Timeline, or the composer waits on a word of this.
            await transcription?.enqueue(mediaId: media.id)
        } catch let error as APIError where error.code == .notFound {
            // The entry or media row is gone server-side. Retrying cannot bring it back.
            media.state = .failed
            try? context.save()
        } catch {
            // Bytes are in storage; only the acknowledgement failed. Stays `uploaded` so the
            // sweep retries *this* leg and never re-sends the file.
            media.attemptCount += 1
            media.nextAttemptAt = UploadBackoff.nextAttempt(after: media.attemptCount)
            if media.nextAttemptAt == nil { media.state = .failed }
            try? context.save()
        }
    }

    // MARK: Sweep

    /// Push every media row that is due. Called by `EntrySync`, so there is one sweep rather
    /// than a parallel media queue with its own policy and its own surface.
    @discardableResult
    func sweep(now: Date = Date()) async -> Int {
        guard !sweeping else { return 0 }
        sweeping = true
        defer { sweeping = false }

        let context = context()
        let inFlight = await uploader.inFlightMediaIds()

        // **Before anything is dispatched.** A row the system has forgotten is invisible to
        // `dueMedia`, so it has to be put back before the queue is read — see the note on the
        // method itself for why this is permanent rather than a race window.
        Self.reconcileStalledUploads(in: context, inFlight: inFlight)

        let due = Self.dueMedia(in: context, now: now, excluding: inFlight)
        for media in due {
            switch media.state {
            case .uploaded:
                // The file is already in storage — only the handshake is outstanding.
                await finishUpload(mediaId: media.id)
            case .staged:
                await beginUpload(mediaId: media.id)
            default:
                continue
            }
        }
        // **Last, and after the uploads.** A derived write resolves a media row the server has to
        // already know about, so a transcript pushed before its own `complete` landed would spend
        // an attempt on a 404 — the same discipline as entries-before-media above.
        await transcription?.sweep(now: now)
        return due.count
    }

    /// Return rows the system has forgotten to `staged`, so the queue can see them again.
    ///
    /// **A row in `uploading` with no live task is stranded permanently, not transiently.** This is
    /// the part worth being precise about: `dueMedia` excludes `uploading` by *state*, not by the
    /// in-flight set, so an empty `inFlightMediaIds()` does not rescue it — the row is skipped by
    /// its own state forever. And nothing else moves it: only the two `URLSessionTask` delegate
    /// callbacks write a row out of `uploading`. There is no timeout, no launch audit, and until now
    /// no foreground audit. `Media.needsUpload`, the one property that excludes `uploading`, is
    /// defined and called from nowhere.
    ///
    /// Two real routes in. iOS discards background tasks — after a reboot, a force quit, or the
    /// system reclaiming the session, the task is gone and the row still believes it is in flight.
    /// And an in-app one: `MediaUploader.finishPart` increments a part's attempt count and sets
    /// `nextAttemptAt` on a failure below the retry cap, but only marks the media `failed` when the
    /// cap is reached — so below the cap the parent row sits in `uploading` with no live task, and
    /// nothing re-dispatches a part. `MediaPart.nextAttemptAt` is written there and read nowhere.
    ///
    /// Returning them to `staged` is safe rather than clever: `staged` means "start over", and
    /// `beginUpload` re-requests an upload URL. **Attempt counts are deliberately untouched** —
    /// this is a reconciliation, not a manual retry, and resetting somebody's backoff ladder here
    /// would let a genuinely failing row spin without ever reaching the cap.
    @discardableResult
    static func reconcileStalledUploads(in context: ModelContext, inFlight: Set<UUID>) -> Int {
        let stranded = ((try? context.fetch(FetchDescriptor<Media>())) ?? []).filter { row in
            row.deletedAt == nil && row.state == .uploading && !inFlight.contains(row.id)
        }
        guard !stranded.isEmpty else { return 0 }
        for row in stranded { row.state = .staged }
        try? context.save()
        return stranded.count
    }

    /// Everything outstanding, for the count the Today row shows.
    static func outstandingCount(in context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { $0.deletedAt == nil && !$0.isComplete }
            .count
    }

    /// The subset of the above that is past the retry cap.
    ///
    /// **A count that mixes these two is reassuring about the wrong rows.** `outstandingCount`
    /// answers "how much is not in the archive", which is the right question for Today; Settings
    /// asks a different one, because "8 files still to upload — they'll finish on their own when
    /// you're back on a good connection" is a promise a `failed` row does not keep. `failed` is
    /// terminal until something asks again, and asking again is exactly what "Retry now" is for.
    static func failedCount(in context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { $0.deletedAt == nil && $0.state == .failed }
            .count
    }

    /// Rows that are due, **ordered by when they became due** rather than by age.
    ///
    /// Oldest-first would let one permanently failing row sit at the head forever: it is
    /// always the oldest, so it is always retried first, and its backoff delays every photo
    /// queued behind it. Ordering by `nextAttemptAt` lets a failing row sink on its own, since
    /// each failure pushes its own eligibility further out.
    static func dueMedia(
        in context: ModelContext,
        now: Date = Date(),
        excluding inFlight: Set<UUID> = []
    ) -> [Media] {
        let all = (try? context.fetch(FetchDescriptor<Media>())) ?? []

        // `POST /media/upload-url` needs an `entry_id` the server recognises. A media row whose
        // entry has not synced yet cannot be uploaded at all — the request 404s — so it is not
        // "due", it is waiting. Ordering the sweep entries-first is not enough on its own: an
        // entry that is failing keeps its media out of the queue rather than burning attempts
        // against a row that cannot succeed.
        let syncedEntryIds = Set(
            ((try? context.fetch(FetchDescriptor<Entry>())) ?? [])
                .filter { $0.deletedAt == nil && $0.sync == .synced }
                .map(\.id)
        )

        return all
            .filter { syncedEntryIds.contains($0.entryId) }
            .filter { media in
                media.deletedAt == nil
                    && !media.isComplete
                    && media.state != .failed
                    && !inFlight.contains(media.id)
                    && (media.state == .staged || media.state == .uploaded)
                    && UploadBackoff.isEligible(nextAttemptAt: media.nextAttemptAt, now: now)
            }
            .sorted { $0.sweepOrderKey < $1.sweepOrderKey }
    }

    /// Rows a parent has to decide about. Surfaced with a retry, never silently dropped.
    static func failedMedia(in context: ModelContext) -> [Media] {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { $0.deletedAt == nil && $0.state == .failed }
    }

    private static func media(id: UUID, in context: ModelContext) -> Media? {
        var descriptor = FetchDescriptor<Media>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
