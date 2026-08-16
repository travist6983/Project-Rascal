import Foundation

/// The sign-in methods on this account, and the magic link that adds one.
///
/// **Linking is explicit, and the client could not do it by email even if it wanted to.** The
/// server never matches a credential on an address, so there is no request here that means
/// "find the account with this email and join it" — only "attach this to the account I am
/// already signed in to". A parent who signs in with Google after Apple gets a second, empty
/// archive; joining the two is a deliberate act from inside a session, which is this file.

// MARK: - Wire types

/// One sign-in method. **`subject_id` is never sent by the server** — `subjectHint` is a masked
/// form carrying just enough to tell two credentials of the same provider apart.
nonisolated struct CredentialSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: UUID
    let provider: String
    let subjectHint: String
    let createdAt: Date
    /// Null means live. A revoked credential stays in the list — a parent who turned one off
    /// and wants it back needs to see that it is off rather than find it missing.
    ///
    /// It is also the "added but not yet verified" state for an `email` credential, which is
    /// why the view asks `isPending` rather than rendering this field directly.
    let revokedAt: Date?

    var isActive: Bool { revokedAt == nil }

    /// An email credential that has been added but whose link has not been opened yet.
    ///
    /// The server reuses `revoked_at` for both "removed" and "not verified", because the
    /// meaning a client needs is identical — *this is not a way in*. The difference matters
    /// only to the copy, and only for email, which is the one provider whose credential is
    /// created inactive.
    var isPending: Bool { provider == "email" && revokedAt != nil }

    /// What a parent reads. Never the raw provider string.
    var displayName: String {
        switch provider {
        case "apple": "Apple"
        case "google": "Google"
        case "email": "Email"
        // A provider added on the server before this build knew about it. Showing the raw key
        // is better than hiding a way into the account.
        default: provider.capitalized
        }
    }
}

private nonisolated struct EmailCredentialRequest: Encodable {
    let provider = "email"
    let email: String
}

// MARK: - Requests

extension APIClient {

    /// `GET /v1/me/credentials` — every sign-in method on this account, oldest first.
    func credentials() async throws -> [CredentialSummary] {
        try await send(.get, "v1/me/credentials")
    }

    /// `POST /v1/me/credentials/email` — add an address, inactive until the link is opened.
    ///
    /// **The address is typed by the parent and must never be defaulted from `users.email`.**
    /// The production account is on a `privaterelay.appleid.com` address, and Apple can stop
    /// forwarding a relay at any time without telling anybody — a magic link to a dead relay is
    /// a key that looks alive. Prefilling this field would be the client quietly choosing the
    /// one address most likely to fail.
    @discardableResult
    func addEmailCredential(_ email: String) async throws -> CredentialSummary {
        try await send(
            .post, "v1/me/credentials/email",
            body: EmailCredentialRequest(email: email)
        )
    }

    /// `DELETE /v1/me/credentials/{id}` — a soft revocation.
    ///
    /// The server **refuses to remove the last live credential**, with `409 last_credential`.
    /// That refusal is shown as a plain sentence rather than an error state: a parent has not
    /// done anything wrong, and the app is declining to let them lock themselves out of
    /// eighteen years of their child's life.
    @discardableResult
    func removeCredential(id: UUID) async throws -> CredentialSummary {
        try await send(.delete, "v1/me/credentials/\(id.uuidString.lowercased())")
    }
}

// `completeEmailSignIn` is **not** here: it mints a session, and the token store it has to write
// is `private` to `APIClient.swift`. Every method that establishes a session lives beside the
// others in that file, which is the right place for them regardless of the access rule that
// forced it.

nonisolated struct EmailSignInCompleteRequest: Encodable {
    let token: String
}
