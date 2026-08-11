import Foundation

/// The two routes that decide where a notification goes.
///
/// Both act on the account behind the bearer token — there is no path parameter naming a user
/// and no way to register a token against somebody else, which is the same shape as `/me`.
extension APIClient {

    /// `POST /v1/devices`.
    ///
    /// **Idempotent, and called on every launch that holds a token.** The same
    /// `(token, environment)` pair updates the existing row rather than creating a second one,
    /// and a token revoked at sign-out comes back live when the same phone signs back in.
    ///
    /// Registering does **not** turn notifications on. That is `notify_enabled` on
    /// `PATCH /v1/me`, and it is only ever set after the parent has granted OS permission.
    @discardableResult
    func registerDevice(token: String, environment: PushEnvironment) async throws -> DeviceResponse {
        try await send(
            .post, "v1/devices",
            body: DeviceRegistrationRequest(
                token: token,
                // `ios` is the only value the server accepts. A browser would need WebPush,
                // which is a different protocol and a different credential.
                platform: "ios",
                environment: environment
            )
        )
    }

    /// `DELETE /v1/devices/{token}` → `204`.
    ///
    /// Called on sign-out, before the session is cleared, because it authenticates with the
    /// session it is revoking against. Soft delete server-side, idempotent, and it revokes
    /// across both environments — a phone that has run a development build and a TestFlight one
    /// holds a row for each, and sign-out means both stop.
    func revokeDevice(token: String) async throws {
        // The token goes in the path, so it is percent-encoded rather than interpolated raw.
        // APNs tokens are hex and would survive either way; relying on that is how a path
        // injection gets shipped the day the format changes.
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        _ = try await send(.delete, "v1/devices/\(escaped)", as: EmptyResponse.self)
    }
}

// MARK: - Wire models

private nonisolated struct DeviceRegistrationRequest: Encodable {
    let token: String
    let platform: String
    /// **No default, deliberately** — the server refuses to guess which host to address, and so
    /// does this client. See `PushEnvironment.current`.
    let environment: PushEnvironment
}

nonisolated struct DeviceResponse: Decodable, Sendable, Equatable {
    let id: UUID
    let token: String
    let platform: String
    let environment: PushEnvironment
    let lastSeenAt: Date
    let createdAt: Date
    let updatedAt: Date
    /// Soft delete, like every other user-data table. A revoked device is a row with this set,
    /// never an absence.
    let revokedAt: Date?
}
