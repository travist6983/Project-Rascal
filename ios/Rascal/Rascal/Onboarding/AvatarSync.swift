import Foundation
import OSLog

/// Moving the bytes: the transfers that do not go through `APIClient`.
///
/// The PUT goes to object storage and the GET comes back from it, both on presigned URLs against
/// a different host with no bearer token — so neither belongs on the API client, and both need a
/// seam so the sweep can be tested without a network.
nonisolated protocol AvatarTransferring: Sendable {
    /// **`contentType` must be byte-identical to the string the URL was presigned for.** The
    /// signature covers `content-type`; a mismatch is a 403 that never says so.
    func put(_ data: Data, to url: URL, contentType: String) async throws
    func get(_ url: URL) async throws -> Data
}

nonisolated struct URLSessionAvatarTransfer: AvatarTransferring {
    enum Failure: Error, Equatable {
        case status(Int)
    }

    /// A plain session, and **deliberately not the background one `MediaUploader` owns.**
    ///
    /// That session is keyed to `Media` rows: its delegate routes every callback by
    /// `task.taskDescription` back to a row in SwiftData, and an avatar has no such row. Giving
    /// avatars a *second* background session would mean a second identifier, a second delegate,
    /// and a second `handleEventsForBackgroundURLSession` path — for one ~40KB PUT.
    ///
    /// It is not needed, because **retry here is the sweep's job rather than the session's**. A
    /// background session earns its complexity by finishing a 70MB video while the app is
    /// suspended; an avatar that does not finish is simply retried on the next foreground, which
    /// is the mechanism this phase was told to use instead of a bespoke loop.
    ///
    /// `waitsForConnectivity` stays false for the same reason: a failure now is more useful than
    /// a request parked indefinitely, because the sweep already knows when to try again. The
    /// intent behind `isDiscretionary = false` — promptness over battery, never defer this — is
    /// kept; the property itself only exists on background configurations.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func put(_ data: Data, to url: URL, contentType: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await Self.session.upload(for: request, from: data)
        try Self.check(response)
    }

    func get(_ url: URL) async throws -> Data {
        let (data, response) = try await Self.session.data(from: url)
        try Self.check(response)
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.status(http.statusCode)
        }
    }
}

/// The child's avatar, kept durable.
///
/// ## What changed, and what did not
///
/// `LocalAvatarStore` is still where an avatar is written and still the first place it is read
/// from. It is now **a cache in front of a durable server copy** rather than the only copy — the
/// same relationship SwiftData already has with the server everywhere else in this app.
///
/// ## The invariant
///
/// **A failed upload never removes the local copy, at any step, for any reason.** A parent who
/// cropped an avatar on a train and watched it appear must not watch it vanish when the network
/// comes back wrong. Uploading is a durability concern; displaying is not, and the two are not
/// allowed to share a failure.
///
/// Order on the way in, and it matters:
///
/// 1. Crop and encode (`AvatarCrop`, unchanged — it already avoids decoding a full-resolution
///    photo to produce 512 pixels).
/// 2. Write to `LocalAvatarStore`. The picture is now safe and visible.
/// 3. Record it as pending.
/// 4. Presign, PUT, commit — any of which may fail, none of which may undo steps 2 or 3.
@MainActor
final class AvatarSync {
    private static let log = Logger(subsystem: "app.rascal", category: "avatar")

    private let api: APIClient
    private let store: AvatarStoring
    private let pending: PendingAvatarUploadStoring
    private let transfer: AvatarTransferring

    /// One sweep at a time, for the reason `EntrySync` gives: two concurrent sweeps would presign
    /// the same avatar twice and leave an extra orphaned object in the bucket for nothing.
    private var running = false

    init(
        api: APIClient,
        store: AvatarStoring = LocalAvatarStore(),
        pending: PendingAvatarUploadStoring = UserDefaultsPendingAvatarUploadStore(),
        transfer: AvatarTransferring = URLSessionAvatarTransfer()
    ) {
        self.api = api
        self.store = store
        self.pending = pending
        self.transfer = transfer
    }

    // MARK: - Coming in

    /// Save an avatar and owe it to the server.
    ///
    /// **Local write first and unconditionally.** Nothing about the network is consulted here and
    /// nothing here can fail in a way the parent sees: by the time this returns, the picture is on
    /// disk and every read path will find it.
    func enqueue(_ jpeg: Data, for childId: UUID, contentType: String = "image/jpeg") {
        store.save(jpeg, for: childId)
        pending.save(
            PendingAvatarUpload(
                childId: childId,
                contentType: contentType,
                byteCount: jpeg.count
            )
        )
    }

    // MARK: - The sweep

    /// Push whatever has not landed. A no-op when nothing is outstanding.
    ///
    /// Called from `EntrySync.sweep()`, which is called on foreground — the same pass that drains
    /// entries and media, rather than a timer or a spinner of its own.
    @discardableResult
    func sweep(now: Date = Date()) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }

        var uploaded = 0
        for record in pending.all().values {
            guard !record.isExhausted else { continue }
            guard UploadBackoff.isEligible(nextAttemptAt: record.nextAttemptAt, now: now) else {
                continue
            }
            if await push(record, now: now) { uploaded += 1 }
        }
        return uploaded
    }

    /// One avatar, all three steps. Returns whether it is now on the server.
    private func push(_ record: PendingAvatarUpload, now: Date) async -> Bool {
        guard let jpeg = store.load(for: record.childId) else {
            // The bytes are gone — the parent removed the avatar, or the app's container was
            // rebuilt. There is nothing to upload and never will be, so the record goes. This is
            // the one path that clears a record without a successful upload, and it clears the
            // record precisely because the local copy is already absent.
            pending.clear(for: record.childId)
            return false
        }

        do {
            // Step 1. Writes nothing server-side.
            let ticket = try await api.avatarUploadTicket(
                childId: record.childId,
                contentType: record.contentType,
                bytes: jpeg.count
            )
            guard let url = URL(string: ticket.uploadUrl) else {
                // A presigned URL that will not parse cannot be retried into working.
                giveUp(record, why: "unparseable upload URL")
                return false
            }

            // Step 2. The same `contentType` that was just presigned for — see
            // `AvatarUploadURLRequest.contentType` for what happens when these differ.
            try await transfer.put(jpeg, to: url, contentType: record.contentType)

            // Step 3. Only now does the child point at these bytes.
            try await api.commitAvatarKey(childId: record.childId, key: ticket.avatarKey)

            pending.clear(for: record.childId)
            Self.log.notice("avatar uploaded for child \(record.childId, privacy: .public)")
            return true
        } catch let error as APIError where isPermanent(error) {
            giveUp(record, why: error.code?.rawValue ?? "refused")
            return false
        } catch {
            reschedule(record, now: now)
            return false
        }
    }

    /// Refusals that retrying cannot fix.
    ///
    /// **The same three codes `EntrySync.push` parks an entry on**, deliberately, so that a phone
    /// that cannot write to this child stops trying for the same reasons everywhere.
    /// `validationFailed` covers a content type outside JPEG/PNG/HEIC and a size outside
    /// 1 byte…5 MiB — both refused at the presign, before anything is written. `notFound` and
    /// `notAuthorized` mean this phone cannot write to this child at all.
    ///
    /// **Not `APIError.isRetryable`, and the difference matters.** That property is the narrower
    /// question "could this identical request succeed right now" — it answers false for
    /// `sessionExpired`, which here would throw away a perfectly good avatar because an access
    /// token lapsed mid-sweep. Everything not named below keeps its record and tries again:
    /// offline, 5xx, an expired session, a 403 on a stale signature. `code` is nil for all of
    /// those anyway, since only `.api` carries one.
    private func isPermanent(_ error: APIError) -> Bool {
        switch error.code {
        case .validationFailed, .notFound, .notAuthorized: true
        default: false
        }
    }

    /// Stop retrying automatically. **The local copy stays.**
    ///
    /// The avatar keeps rendering from disk exactly as before; what is lost is only the durability
    /// this phase adds, and losing it silently is correct — a parent cannot act on "the avatar
    /// presign was refused", and saying so on the Settings screen would be an error message about
    /// a picture that is visibly right there.
    private func giveUp(_ record: PendingAvatarUpload, why: String) {
        pending.clear(for: record.childId)
        Self.log.error("avatar upload refused for child \(record.childId, privacy: .public): \(why, privacy: .public)")
    }

    /// Offline, a 5xx, a 403 on a signature. All worth another attempt, on the shared schedule.
    private func reschedule(_ record: PendingAvatarUpload, now: Date) {
        var updated = record
        updated.attemptCount += 1
        updated.nextAttemptAt = UploadBackoff.nextAttempt(after: updated.attemptCount, now: now)
        pending.save(updated)
    }

    // MARK: - Reading it back

    /// The avatar's bytes, from the nearest place that has them.
    ///
    /// **Local cache, then the server, and only then.** After a normal launch the file is already
    /// here and this makes no request at all; after a fresh install it makes exactly one, once,
    /// and caches the result so the next launch is local again.
    ///
    /// `remoteKey` is `ChildResponse.avatarKey`, which arrives on the launch path for free — so a
    /// child with no avatar costs **zero requests** rather than a round trip that 404s. The 404 is
    /// still handled, because the key can be stale by the width of one sync.
    ///
    /// Returns `nil` for "no avatar", which every caller renders as the initials disc. Nil is never
    /// an error here: not for a 404, not for being offline. There is no retry and no log line,
    /// because there is nothing a parent could do with either.
    func avatarData(for childId: UUID, remoteKey: String?) async -> Data? {
        if let cached = store.load(for: childId) { return cached }
        guard remoteKey != nil else { return nil }

        do {
            let ticket = try await api.avatarReadTicket(childId: childId)
            guard let url = URL(string: ticket.url) else { return nil }
            let data = try await transfer.get(url)
            // Cached so the next read is local. This is the fresh-install path becoming the
            // ordinary path.
            store.save(data, for: childId)
            return data
        } catch {
            // **Three different facts land here and all three render the same thing.**
            //
            // 1. Our route 404s — the key was cleared between `GET /children` and now. Narrow.
            // 2. The presigned GET 404s — the key is set but the object has gone. **This is the
            //    realistic stale case, and it does not surface as a 404 from our route:**
            //    `presign_avatar_read` only checks `avatar_key IS NULL` and never asks storage,
            //    so a dead key still returns 200 and a valid URL. Verified against the live API.
            // 3. Offline.
            //
            // Nothing is cached on any of them, so a later launch tries again rather than
            // remembering an empty file. Nothing is retried here and nothing is logged, because
            // there is no version of this a parent could act on.
            return nil
        }
    }
}
