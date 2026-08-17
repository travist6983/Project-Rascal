import Foundation

/// The household, and the invite that adds a second parent to it.
///
/// **Nothing here decides who may see a child.** `guardians` rows do, on the server, and
/// accepting an invite is the server writing them — so this file creates and reads invites and
/// never grants anything itself. A client that filtered a household locally would be a second
/// opinion about access, which is the one thing this API is careful never to have.
///
/// **The raw invite token exists once.** `POST /v1/families/me/invites` returns it and the
/// server stores only its SHA-256, so a link that is dismissed instead of shared is gone and a
/// new invite has to be created. The UI says that in a sentence rather than pretending it can
/// be recovered.

// MARK: - Wire types

nonisolated struct GuardianSummary: Decodable, Equatable, Sendable, Identifiable {
    let userId: UUID
    /// Nullable everywhere it comes from: a parent who signed in through Apple's private relay
    /// and skipped onboarding has never told us a name.
    let displayName: String?
    let role: String
    /// **Nullable.** A household member with no guardian row — a household whose only child was
    /// deleted, or a member mid-accept — has no grant date, and the server sends null rather
    /// than inventing one.
    let grantedAt: Date?
    /// True for the caller, so the list can say "you" without comparing ids itself.
    let isYou: Bool

    var id: UUID { userId }

    /// What a parent reads. Never a raw id, and never an empty string.
    var displayLabel: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return displayName
        }
        return isYou ? "You" : "The other parent"
    }
}

nonisolated struct InviteSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: UUID
    let email: String?
    let role: String
    let expiresAt: Date
    let createdAt: Date
}

/// The one response that carries the raw token, and the only time it exists.
nonisolated struct CreatedInvite: Decodable, Equatable, Sendable {
    let id: UUID
    let email: String?
    let role: String
    let expiresAt: Date
    let createdAt: Date
    let token: String
}

nonisolated struct FamilySummary: Decodable, Equatable, Sendable {
    let familyId: UUID
    /// `free` or `subscribed`. **The server is the only thing that decides this** — the device
    /// never does, for the same reason it never decides what day it is.
    let tier: String
    let guardians: [GuardianSummary]
    /// Only invites still acceptable. Accepted, revoked and expired ones are history.
    let pendingInvites: [InviteSummary]

    var isSubscribed: Bool { tier == "subscribed" }

    /// Two adults is the household. A third is a different product, not a bigger bill, so the
    /// invite affordance disappears rather than offering an upsell that goes nowhere.
    var isFull: Bool { guardians.count >= 2 }
}

/// What an unauthenticated caller may learn from a link before signing in.
///
/// Deliberately thin — who invited you, the role, when it expires, and the children's **first
/// names**. Enough for the right person to recognise their own household; not enough to be
/// worth harvesting.
nonisolated struct InvitePreview: Decodable, Equatable, Sendable {
    let invitedBy: String?
    let role: String
    let expiresAt: Date
    let children: [String]
}

nonisolated struct AcceptedInvite: Decodable, Equatable, Sendable {
    let familyId: UUID
    let children: [UUID]
}

private nonisolated struct CreateInviteRequest: Encodable {
    let email: String?
    let role: String
}

// MARK: - Requests

extension APIClient {

    /// `GET /v1/families/me` — the caller's own household.
    ///
    /// No id in the path, so there is nothing to forge and no `child_access` to run.
    func family() async throws -> FamilySummary {
        try await send(.get, "v1/families/me")
    }

    /// `POST /v1/families/me/invites` — mint a link, and receive its raw token **once**.
    ///
    /// Three refusals worth telling apart at the call site, all by `APIError.code`:
    ///
    /// * `.subscriptionRequired` (402) — the household is on the free tier. Per D4 the second
    ///   guardian is what the subscription is sold on, so this is the upgrade surface. **Not a
    ///   permission error**: they may do this, they have not bought it yet.
    /// * `.conflict` (409) — the household already has two parents.
    /// * `.validationFailed` (422) — a role other than `parent`; `viewer` is phase 30 and iced.
    ///
    /// `email` is optional and is only recorded — **nothing sends it**. The client delivers the
    /// link, which is why the caller presents a share sheet rather than a confirmation.
    func createInvite(email: String? = nil) async throws -> CreatedInvite {
        try await send(
            .post, "v1/families/me/invites",
            body: CreateInviteRequest(email: email, role: "parent")
        )
    }

    /// `DELETE /v1/families/me/invites/{id}` — withdraw an outstanding invite. Idempotent.
    ///
    /// An invite belonging to another household answers `404`, not `403` — the caller has no
    /// business knowing it exists.
    func revokeInvite(id: UUID) async throws {
        let _: EmptyResponse = try await send(
            .delete, "v1/families/me/invites/\(id.uuidString.lowercased())"
        )
    }

    /// `GET /v1/invites/{token}` — **unauthenticated on purpose.**
    ///
    /// You have to be able to see what a link is before you sign in to accept it. An unknown,
    /// expired, revoked or already-spent token is a flat `404` rather than a `410`: the caller
    /// is a stranger at this point, and that a token once existed is more than they need.
    func invitePreview(token: String) async throws -> InvitePreview {
        try await send(.get, "v1/invites/\(Self.escape(token))", authenticated: false)
    }

    /// `POST /v1/invites/{token}/accept` — join the household. Authenticated, because it writes
    /// to the caller's own account.
    ///
    /// **Idempotent.** The same user accepting the same link twice succeeds twice and writes
    /// nothing the second time — a parent who taps, loses signal and taps again gets a
    /// household, not an error.
    ///
    /// The children arrive locally through the **existing pull path** afterwards. There is no
    /// special-case importer here, because the server is the source of truth and a second way
    /// for a child to appear locally is a second thing to keep correct.
    @discardableResult
    func acceptInvite(token: String) async throws -> AcceptedInvite {
        try await send(.post, "v1/invites/\(Self.escape(token))/accept")
    }

    /// A token goes in the path, so it is percent-encoded rather than interpolated raw — the
    /// same rule and the same character set as `revokeDevice`. Invite tokens are
    /// `secrets.token_urlsafe` and would survive either way; relying on that is how a path
    /// injection gets shipped the day the format changes.
    static func escape(_ token: String) -> String {
        token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
    }
}
