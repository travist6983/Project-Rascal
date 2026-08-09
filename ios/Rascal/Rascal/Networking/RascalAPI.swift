import Foundation

/// The endpoints this phase uses. One place that knows path strings, so a contract change is
/// a single edit rather than a search across views.
extension APIClient {

    func today(childId: UUID, date: String? = nil) async throws -> TodayResponse {
        let path = date.map { "v1/children/\(childId.uuidString.lowercased())/today?date=\($0)" }
            ?? "v1/children/\(childId.uuidString.lowercased())/today"
        return try await send(.get, path)
    }

    func children() async throws -> [ChildResponse] {
        try await send(.get, "v1/children")
    }

    /// `GET /v1/me` — the account behind the bearer token.
    ///
    /// The user record otherwise arrives exactly once, with the sign-in response, so a relaunch
    /// on a stored token has a valid session and no idea whose it is. There is no path parameter
    /// and no way to name another user.
    func me() async throws -> UserResponse {
        try await send(.get, "v1/me")
    }

    /// The assignment flips to `done` in the same transaction that creates the entry, so this
    /// is the only call a completion needs.
    ///
    /// `Idempotency-Key` makes a retry safe: a replay returns the original 201 body
    /// byte-for-byte, never a second row and never a 409. That is what lets a failed save sit
    /// in SwiftData and retry on next foreground without risking a duplicate.
    func createEntry(_ entry: Entry, tags: [String] = []) async throws -> EntryResponse {
        try await send(
            .post, "v1/entries",
            body: EntryCreateRequest(
                id: entry.id,
                childId: entry.childId,
                assignmentId: entry.assignmentId,
                occurredAt: entry.occurredAt,
                title: entry.title,
                body: entry.body,
                unlockAtAge: entry.unlockAtAge,
                tags: tags
            ),
            headers: ["Idempotency-Key": entry.idempotencyKey.uuidString]
        )
    }

    func dismissAssignment(_ id: UUID) async throws {
        _ = try await send(.post, "v1/assignments/\(id.uuidString.lowercased())/dismiss", as: EmptyResponse.self)
    }
}

nonisolated struct ChildResponse: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let birthdate: String
    let familyTimezone: String
    let ageMonths: Int
    let role: String
}

// MARK: - Media

nonisolated struct UploadPart: Decodable {
    let partNumber: Int
    let uploadUrl: String
}

nonisolated struct UploadTicket: Decodable {
    let mediaId: UUID
    let s3Key: String
    /// Exactly one of these is set. Single PUT under the multipart threshold.
    let uploadUrl: String?
    /// Present instead of `uploadUrl` when the object is large enough to need multipart. The
    /// count is the server's, computed from `chunkBytes`.
    let parts: [UploadPart]?
    let multipart: Bool
    /// **Null on the single-PUT path, which is normal.** Stored rather than read: the
    /// multipart phase must split at the server's number instead of assuming 8MB.
    let chunkBytes: Int?
    let expiresIn: Int

    var uploadURL: String? { uploadUrl }
}

private nonisolated struct UploadURLRequest: Encodable {
    let mediaId: UUID
    let entryId: UUID
    let kind: String
    let filename: String
    let bytes: Int
    let contentType: String
}

private nonisolated struct CompletedPart: Encodable {
    let partNumber: Int
    let etag: String
}

/// `MediaDerivedRequest`. Every field on the server is optional; this client only ever fills one.
private nonisolated struct MediaDerivedRequest: Encodable {
    let transcript: String
}

/// `MediaDerivedResponse` — the updated media row, plus every tag on its entry afterwards.
///
/// `media` decodes as `SyncMediaResponse` because the two are the same server type: `MediaOut`.
/// A second Swift struct for one JSON shape is two things to keep in step.
private nonisolated struct MediaDerivedResponse: Decodable {
    let media: SyncMediaResponse
    let tags: [TagResponse]
}

/// The two fields the caller actually uses, lifted out so the wire type stays private.
///
/// `updatedAt` is the trigger's own value, not this device's clock — the API has a test named
/// for that. Writing it onto the row is what keeps the next pull comparing two server timestamps.
nonisolated struct MediaDerivedResult: Sendable {
    let transcript: String?
    let updatedAt: Date
}

private nonisolated struct CompleteRequest: Encodable {
    /// Required for multipart, ignored for a single PUT — the server's own rule decides which,
    /// so the client sends what it has rather than branching on file size.
    let etags: [CompletedPart]?
    let capturedAt: Date?
    let durationSeconds: Int?
}

extension APIClient {
    /// Presign a destination. `media_id` is sent rather than assigned, so the staged file has
    /// a name before any request — an offline client mints the id alongside its entry.
    func mediaUploadURL(
        mediaId: UUID,
        entryId: UUID,
        kind: String,
        filename: String,
        bytes: Int,
        contentType: String
    ) async throws -> UploadTicket {
        try await send(
            .post, "v1/media/upload-url",
            body: UploadURLRequest(
                mediaId: mediaId,
                entryId: entryId,
                kind: kind,
                filename: filename,
                bytes: bytes,
                contentType: contentType
            )
        )
    }

    /// Acknowledge the object.
    ///
    /// The ETag is deliberately not sent: the server ignores `etags` unless the upload was
    /// multipart, and multipart is out of scope this phase. It is captured and stored on the
    /// row anyway — an integrity value now, and the mechanism multipart will need.
    @discardableResult
    func completeMedia(
        mediaId: UUID,
        etags: [(part: Int, etag: String)] = [],
        capturedAt: Date?,
        durationSeconds: Int?
    ) async throws -> EmptyResponse {
        try await send(
            .post, "v1/media/\(mediaId.uuidString.lowercased())/complete",
            body: CompleteRequest(
                // Sorted by part number: the server assembles in the order it is given, and an
                // out-of-order list produces a corrupt object rather than an error.
                etags: etags.isEmpty ? nil : etags.sorted { $0.part < $1.part }
                    .map { CompletedPart(partNumber: $0.part, etag: $0.etag) },
                capturedAt: capturedAt,
                durationSeconds: durationSeconds
            ),
            as: EmptyResponse.self
        )
    }

    /// `PATCH /v1/media/{id}/derived` — make on-device AI output permanent.
    ///
    /// The phone is an inference worker and this is where its output stops being local. **The
    /// server never regenerates a transcript**, and a browser in 2027 will never have a model to
    /// regenerate it with, so a transcript that does not reach this endpoint does not exist.
    ///
    /// Documented idempotent: the same transcript twice changes nothing, which is what makes the
    /// retry after a crash between the local write and this call safe rather than merely likely
    /// to work.
    ///
    /// **`caption` and `tags` are deliberately not sent.** This phase transcribes and nothing
    /// else. Sending nil for a field the client has no opinion about is the same mistake
    /// `updateEntry` avoids with `title` — a call that claims more than it knows.
    @discardableResult
    func writeDerived(mediaId: UUID, transcript: String) async throws -> MediaDerivedResult {
        let response: MediaDerivedResponse = try await send(
            .patch, "v1/media/\(mediaId.uuidString.lowercased())/derived",
            body: MediaDerivedRequest(transcript: transcript)
        )
        return MediaDerivedResult(
            transcript: response.media.transcript,
            updatedAt: response.media.updatedAt
        )
    }

    /// A short-lived read URL. The bucket is private, so this is the only way to fetch bytes.
    func mediaDownloadURL(mediaId: UUID) async throws -> String {
        struct Response: Decodable { let url: String }
        let response: Response = try await send(
            .get, "v1/media/\(mediaId.uuidString.lowercased())/url"
        )
        return response.url
    }
}

extension APIClient {
    /// Edit an existing entry from the composer. Body and `occurred_at` — the two things it can
    /// actually change. Media after save is a later phase, and `entry_type` stays server-derived.
    ///
    /// Both are sent as *set*, including when nil, because an omitted key would make "the parent
    /// cleared the text" indistinguishable from "the parent didn't touch it", and the old words
    /// would stay in the archive.
    ///
    /// **`title` is deliberately not sent.** The composer has no title field, so this call has no
    /// opinion about titles and must not express one — sending the locally cached value would
    /// mean editing a body on a stale row quietly reverts a title someone set on another phone.
    /// A call that claims more than it knows is how last-write-wins turns into last-open-wins.
    @discardableResult
    func updateEntry(_ entry: Entry) async throws -> EntryResponse {
        try await updateEntry(
            id: entry.id,
            changes: EntryChanges(
                body: .set(entry.body),
                occurredAt: .set(entry.occurredAt)
            )
        )
    }
}

private nonisolated struct BoardResetRequest: Encodable {
    let childId: UUID
    let kinds: [String]
}

nonisolated struct BoardResetResponse: Decodable {
    let date: String
    let cleared: Int
    let created: [String]
    /// Kinds with no active prompt to serve — audio, today. Reported rather than silently
    /// producing a shorter board than was asked for.
    let unavailable: [String]
}

extension APIClient {
    /// Rebuild today as one assignment per kind. **Local builds only** — `/v1/debug/*` is not
    /// registered when the API runs with `ENVIRONMENT=prod`, so this 404s anywhere real.
    @discardableResult
    func resetBoard(
        childId: UUID,
        kinds: [String] = ["question", "photo", "video", "audio", "activity"]
    ) async throws -> BoardResetResponse {
        try await send(
            .post, "v1/debug/board",
            body: BoardResetRequest(childId: childId, kinds: kinds)
        )
    }
}
