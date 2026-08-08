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

    private let api: APIClient
    private let store: StagingStore
    private let uploader: MediaUploader
    private var sweeping = false

    init(api: APIClient, store: StagingStore = StagingStore(), uploader: MediaUploader = .shared) {
        self.api = api
        self.store = store
        self.uploader = uploader
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
        } catch {
            media.recordAttemptFailure()
            try? context.save()
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

        do {
            try await api.completeMedia(
                mediaId: media.id,
                capturedAt: media.capturedAt,
                durationSeconds: media.durationSeconds
            )
            media.state = .complete
            media.attemptCount = 0
            media.nextAttemptAt = nil
            try? context.save()
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
        return due.count
    }

    /// Everything outstanding, for the count the Today row shows.
    static func outstandingCount(in context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { $0.deletedAt == nil && !$0.isComplete }
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
