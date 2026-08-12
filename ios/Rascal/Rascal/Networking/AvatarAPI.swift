import Foundation

/// The child's avatar on the wire: presign it in, commit it, presign it back out.
///
/// Three calls, always in this order, and the order is the contract rather than a convention.
/// From `api/src/rascal/services/avatars.py`:
///
/// > The caller `PATCH`es `avatar_key` onto the child once the PUT succeeds, so a presign that
/// > the phone abandons leaves an orphaned object rather than a child record pointing at bytes
/// > that never arrived. Of the two, only the second is visible to a parent.
///
/// So the key is **committed last**, never optimistically. A phone that presigns and then loses
/// its connection has cost the bucket one unreferenced object; a phone that committed first would
/// have cost the parent a broken picture of their child.
///
/// Deliberately **not** the media path. `POST /media/upload-url` requires an `entry_id` and writes
/// a `media` row, which would file a picture of the child in the archive as some entry's artifact.
/// An avatar is a property of the child and is keyed like one, in `children.avatar_key`.

// MARK: - Responses

/// `POST /v1/children/{id}/avatar-upload-url`.
///
/// No `multipart`, no `parts`, and no `chunkBytes`, unlike `UploadTicket` — an avatar is a ~512px
/// square and the multipart machinery exists for video. One PUT, always.
nonisolated struct AvatarUploadTicket: Decodable, Equatable, Sendable {
    /// Named for the snake_case key it decodes from, like `UploadTicket.uploadUrl`.
    let uploadUrl: String
    /// **A fresh UUID per presign, not a stable `avatar.jpg`.** `build_avatar_key` picks a new one
    /// every time so that a replaced avatar is distinguishable from a corrupted one — which means
    /// the client cannot derive this and must store the one it was handed.
    let avatarKey: String
    let expiresIn: Int

    var uploadURL: String { uploadUrl }
}

/// `GET /v1/children/{id}/avatar-url`.
///
/// The field is `url`, not `avatar_url`. **Minted per request and never persisted** — a stored
/// signed URL outlives its signature and then fails in a way that looks like the archive lost the
/// picture. Persist `avatar_key`; refetch this.
nonisolated struct AvatarReadTicket: Decodable, Equatable, Sendable {
    let url: String
    let expiresIn: Int
}

// MARK: - Requests

private nonisolated struct AvatarUploadURLRequest: Encodable {
    /// **The exact string the PUT must then send as its `Content-Type`.**
    ///
    /// The presigned URL carries `X-Amz-SignedHeaders=content-type;host`, so the header is part of
    /// the signature. Sending `application/octet-stream` against a URL signed for `image/jpeg`, or
    /// omitting the header and letting `URLSession` infer one, is a 403 `SignatureDoesNotMatch`
    /// whose XML never mentions `Content-Type`. Verified in curl during preflight — see
    /// `docs/reports/phase-21-preflight.md`.
    let contentType: String
    let bytes: Int
}

/// Only `avatar_key`, and that is the whole point of it existing separately.
///
/// `updateChild` sends name, birthdate, timezone and pronouns and documents `avatar_key` as
/// deliberately absent. The server reads `model_fields_set`, so a request carrying only this key
/// leaves every other column alone — and the edit sheet stays unable to touch the avatar by
/// accident.
private nonisolated struct AvatarKeyUpdateRequest: Encodable {
    let avatarKey: String
}

// MARK: - Calls

extension APIClient {

    /// Step 1. Presign one PUT. **Writes nothing** — no row changes until `commitAvatarKey`.
    func avatarUploadTicket(
        childId: UUID,
        contentType: String,
        bytes: Int
    ) async throws -> AvatarUploadTicket {
        try await send(
            .post, "v1/children/\(childId.uuidString.lowercased())/avatar-upload-url",
            body: AvatarUploadURLRequest(contentType: contentType, bytes: bytes)
        )
    }

    /// Step 3. Point the child at bytes that are now definitely in storage.
    ///
    /// Returns `ChildUpdateResponse` rather than `ChildResponse`: `PATCH` answers with `ChildOut`,
    /// which carries no `role` and no `age_months`, and decoding one into the other would fail on
    /// the two missing keys.
    @discardableResult
    func commitAvatarKey(childId: UUID, key: String) async throws -> ChildUpdateResponse {
        try await send(
            .patch, "v1/children/\(childId.uuidString.lowercased())",
            body: AvatarKeyUpdateRequest(avatarKey: key)
        )
    }

    /// A short-lived read URL.
    ///
    /// **Throws `notFound` when the child has no avatar, and that is a normal answer.** The route
    /// 404s rather than returning a null URL so that "this child has no avatar" and "here is a URL
    /// that will not resolve" stay different answers. Callers branch on it; nothing surfaces it.
    func avatarReadTicket(childId: UUID) async throws -> AvatarReadTicket {
        try await send(.get, "v1/children/\(childId.uuidString.lowercased())/avatar-url")
    }
}
