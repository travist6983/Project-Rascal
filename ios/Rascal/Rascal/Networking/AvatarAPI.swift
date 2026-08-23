import Foundation

/// The child's avatar on the wire: presign it in, commit it, presign it back out — and clear it.
///
/// The first three are always in this order, and the order is the contract rather than a
/// convention.
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
/// **The fourth is a removal, and it has no storage half at all** — there is no DELETE for an
/// avatar and nothing takes the object out of the bucket. Clearing `children.avatar_key` is the
/// whole operation; see `clearAvatarKey`.
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

/// Clearing it, and **the hand-written encoder is the entire reason this is its own type.**
///
/// Swift's synthesized `Encodable` writes optionals through `encodeIfPresent`, which *omits* a nil
/// rather than emitting one. The server dumps the payload with `exclude_unset`, so an omitted
/// `avatar_key` reads as "no opinion" and the column is left exactly as it was. A clear written the
/// obvious way — `let avatarKey: String?` and pass nil — compiles, sends `{}`, gets a 200 back with
/// the child's row unchanged, and looks for all the world like it worked.
///
/// `ChildUpdateRequest` in `SettingsAPI.swift` is hand-written for precisely this reason on
/// `pronouns`, and says so at its `encode(to:)`. This uses `encodeNil`, which has no omitting
/// variant to reach for by mistake.
private nonisolated struct AvatarKeyClearRequest: Encodable {
    /// `convertToSnakeCase` still applies, so this lands on the wire as `avatar_key` — the same
    /// note `SettingsAPI.swift:109` already makes about its own written-out keys.
    enum CodingKeys: String, CodingKey { case avatarKey }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .avatarKey)
    }
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

    /// Clear this child's avatar. **The only call in the client that sends `avatar_key: null`.**
    ///
    /// Deliberately not `updateChild`, which always sends name, birthdate and family_timezone —
    /// routing a removal through it would rewrite three unrelated columns and move their
    /// `updated_at` for a change that touched none of them. It is also what keeps
    /// `SettingsTests.doesNotTouchAvatar` true: the edit sheet still cannot reach the avatar.
    ///
    /// **The object in the bucket is not deleted, and nothing here claims it is.**
    /// `s3.delete_objects` has one caller in the API, fed by media keys through entries, and it
    /// never sees `children.avatar_key`. Clearing the column orphans the object — the same trade
    /// the presign-then-commit ordering above already accepts, where an abandoned presign leaves
    /// one unreferenced object behind.
    @discardableResult
    func clearAvatarKey(childId: UUID) async throws -> ChildUpdateResponse {
        try await send(
            .patch, "v1/children/\(childId.uuidString.lowercased())",
            body: AvatarKeyClearRequest()
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
