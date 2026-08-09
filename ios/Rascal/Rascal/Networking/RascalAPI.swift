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

nonisolated struct ChildResponse: Decodable, Identifiable {
    let id: UUID
    let name: String
    let birthdate: String
    let familyTimezone: String
    let ageMonths: Int
    let role: String
}

// MARK: - Media

nonisolated struct UploadTicket: Decodable {
    let mediaId: UUID
    let s3Key: String
    /// Exactly one of these is set. Single PUT under the multipart threshold.
    let uploadUrl: String?
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

private nonisolated struct CompleteRequest: Encodable {
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
        capturedAt: Date?,
        durationSeconds: Int?
    ) async throws -> EmptyResponse {
        try await send(
            .post, "v1/media/\(mediaId.uuidString.lowercased())/complete",
            body: CompleteRequest(capturedAt: capturedAt, durationSeconds: durationSeconds),
            as: EmptyResponse.self
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

private nonisolated struct EntryUpdateRequest: Encodable {
    let occurredAt: Date
    let title: String?
    let body: String?
}

extension APIClient {
    /// Edit an existing entry. Title, body, and `occurred_at` only — media after save is a
    /// later phase, and `entry_type` stays server-derived.
    @discardableResult
    func updateEntry(_ entry: Entry) async throws -> EntryResponse {
        try await send(
            .patch, "v1/entries/\(entry.id.uuidString.lowercased())",
            body: EntryUpdateRequest(
                occurredAt: entry.occurredAt,
                title: entry.title,
                body: entry.body
            )
        )
    }
}
