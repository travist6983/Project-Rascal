import Foundation

/// The endpoints Settings writes through, plus the one it downloads.
///
/// Same shape as the rest of the client: one place that knows path strings, so a contract
/// change is a single edit rather than a search across sheets.
extension APIClient {

    /// `PATCH /v1/children/{id}` — parent only.
    ///
    /// Sends exactly the three fields the sheet edits. `avatar_key` is deliberately absent:
    /// the server uses `exclude_unset`, so a key that is not sent is not touched, and avatar
    /// belongs with the media path rather than here.
    ///
    /// **This does not recompute stored ages, and must not.** `entries.child_age_months` is
    /// computed at write and stored precisely so a birthdate typo cannot silently reshape five
    /// hundred entries — see `docs/decisions.md`. The correction is `recomputeAges`, and it is
    /// the parent's to pull.
    @discardableResult
    func updateChild(
        id: UUID,
        name: String,
        birthdate: String,
        familyTimezone: String
    ) async throws -> ChildUpdateResponse {
        try await send(
            .patch, "v1/children/\(id.uuidString.lowercased())",
            body: ChildUpdateRequest(
                name: name,
                birthdate: birthdate,
                familyTimezone: familyTimezone
            )
        )
    }

    /// `PATCH /v1/me`. No path parameter by design — it updates the row behind the bearer
    /// token and there is no way to name another user.
    ///
    /// **Every field is optional and an absent key means "no opinion".** The server reads
    /// `model_fields_set`, so a Settings screen toggling notifications must not resend a display
    /// name it is not changing, and a screen renaming the parent must not resend a notification
    /// preference. Swift's synthesized encoder uses `encodeIfPresent` for optionals, which is
    /// exactly that behaviour — a nil property is omitted rather than sent as `null`.
    ///
    /// **Sending an explicit `null` would be a rejection, not a clear.** None of the three
    /// columns is nullable, so there is no "unset" to express and nothing here tries to.
    ///
    /// Email is absent entirely. It comes from the credential provider; Apple's relay address is
    /// not the user's to retype.
    @discardableResult
    func updateMe(
        displayName: String? = nil,
        notifyEnabled: Bool? = nil,
        notifyLocalTime: NotifyTime? = nil
    ) async throws -> UserResponse {
        try await send(
            .patch, "v1/me",
            body: MeUpdateRequest(
                displayName: displayName,
                notifyEnabled: notifyEnabled,
                notifyLocalTime: notifyLocalTime
            )
        )
    }

    /// `POST /v1/children/{id}/recompute-ages` — parent only, no body.
    ///
    /// Rewrites every entry's stored age from its own `occurred_at` against the child's current
    /// birthdate. Only rows that actually change are written, so the correction reaches other
    /// devices through `/sync` without dragging the whole archive behind it. Idempotent: a
    /// second call returns `entries_updated: 0`.
    func recomputeAges(childId: UUID) async throws -> RecomputeAgesResponse {
        try await send(
            .post, "v1/children/\(childId.uuidString.lowercased())/recompute-ages",
            body: Optional<Never>.none
        )
    }
}

// MARK: - Wire models

private nonisolated struct ChildUpdateRequest: Encodable {
    let name: String
    /// `yyyy-MM-dd`. A **calendar day, not an instant** — sent as a string rather than a `Date`
    /// because the client's encoder writes ISO 8601 with a time and a zone, and a birthday has
    /// neither. Encoding one as a timestamp is how a birthdate lands a day early west of
    /// Greenwich.
    let birthdate: String
    let familyTimezone: String
}

/// All three optional, so the encoder omits whatever the caller had no opinion about. See
/// `updateMe` for why that distinction is load-bearing.
private nonisolated struct MeUpdateRequest: Encodable {
    let displayName: String?
    let notifyEnabled: Bool?
    /// `"HH:mm:ss"`. A wall-clock time read in the child's `family_timezone` — see `NotifyTime`,
    /// which is why this is not a `Date`.
    let notifyLocalTime: NotifyTime?
}

/// `ChildOut` — what `PATCH /children/{id}` returns.
///
/// Deliberately not `ChildResponse`, which is `ChildWithRole` from `GET /children` and carries
/// `role` and `age_months` that this response does not. Decoding one into the other would fail
/// on the two missing keys, and papering over that by making them optional would hide which
/// endpoint answers with what.
nonisolated struct ChildUpdateResponse: Decodable, Sendable {
    let id: UUID
    let name: String
    let birthdate: String
    let avatarKey: String?
    let familyTimezone: String
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct RecomputeAgesResponse: Decodable, Sendable {
    let childId: UUID
    /// Rows changed, not rows examined. A second call immediately after returns 0.
    let entriesUpdated: Int
    /// Echoed back, because the point of the call is that the birthdate was just corrected and
    /// a screen saying "412 entries updated" wants to say what they were corrected *to*.
    let birthdate: String
}
