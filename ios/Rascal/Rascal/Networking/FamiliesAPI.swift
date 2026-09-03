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

    /// **Whether the server queued an invite email — not whether one arrived.** Added by the
    /// API's phase 136; the send runs after that response, so delivery is not something the
    /// `201` could honestly claim.
    ///
    /// **Optional, because a server that predates the field sends no key at all** and Swift's
    /// synthesized `Decodable` does not fall back to a property default for a missing key — a
    /// non-optional `Bool` here would fail the whole decode against every server now running and
    /// take the invite flow down with it. Read it through `wasEmailed`.
    let emailQueued: Bool?

    /// `emailQueued` with absent and `false` collapsed, which is every state that exists. Absent
    /// means an older server, which never mails, so `false` is the correct reading of both.
    var wasEmailed: Bool { emailQueued ?? false }
}

nonisolated struct FamilySummary: Decodable, Equatable, Sendable {
    let familyId: UUID
    /// `free` or `subscribed`. **The server is the only thing that decides this** — the device
    /// never does, for the same reason it never decides what day it is.
    let tier: String

    /// What this household may be served, added to `/families/me` by phase 107.
    ///
    /// **`tier` cannot answer this and never could.** It is constrained to `free | subscribed` —
    /// *"there is deliberately no `trial` value here"* — so a household three days into its trial
    /// and one whose fortnight ended a year ago are both `free`. Anything that needs to tell those
    /// apart has to read this.
    ///
    /// Optional because a server predating phase 107 does not send it, and absent must stay
    /// distinguishable from `free`.
    let access: Access?

    /// When the subscription lapsed. **Null on a household that has never subscribed as well as on
    /// one that currently is** — `tier` is what tells those apart, which is why this alone cannot
    /// answer "are they lapsed".
    ///
    /// Added by phase 113. **A trial expiring never writes it**: `lapsed_at` is about a
    /// *subscription* ending, and a trial quietly running out must not read as a lapse.
    ///
    /// **Decoded and rendered by nothing.** `free-tier-copy.md` has no string for the lapsed state,
    /// and the copy file forbids an agent writing one — so this is carried, not shown, until the
    /// owner approves the words. See *Proposed additions* 6.
    let lapsedAt: Date?

    /// `annual` | `monthly`, or null. Added by phase 113, derived from the most recent App Store
    /// transaction's `product_id` through a **lookup, never a substring parse**.
    ///
    /// **Null is a real answer and is not a guess**: no transaction row, an unrecognised product id,
    /// **or the household is not currently subscribed.** That last clause is a server-side
    /// invariant, so `plan` can never arrive beside `access: "free"` — a household that lapsed from
    /// annual reports null, not `"annual"`.
    ///
    /// **A `String?` rather than an enum, deliberately.** Nothing renders it — the Settings row has
    /// no approved copy for annual-vs-monthly, and Apple's own sheet already shows the plan, which
    /// the brief calls a fallback rather than a gap. A `String?` cannot fail to decode a third value
    /// a later server invents, which is the only property this field needs today.
    let plan: String?

    /// The card is failing and Apple is still retrying. Added by phase 113.
    ///
    /// **`bool` non-optional on the wire — and `Bool?` here, which is not a disagreement.** The two
    /// answer different questions: the *server* always sends a value, so `false` and "not in grace"
    /// are the same thing there; the *client* must also survive a server that predates the field and
    /// sends no key at all — which is production, today, until 113 deploys.
    ///
    /// **Swift's synthesized `Decodable` does not fall back to a property's default value for a
    /// missing key.** A non-optional `Bool` here would make the whole of `FamilySummary` fail to
    /// decode against every server now running, taking the entire membership card with it. Read it
    /// through `isInBillingRetry`, which collapses the tri-state back to the two states that exist.
    ///
    /// **It gates nothing, and that is the point.** A household in grace still reads
    /// `access: "subscribed"` and is still fully entitled — keeping the archive open while Apple
    /// retries is the product call, and this field exists so a client can *say* something without
    /// the gate moving. Nothing says anything yet: there is no approved copy for grace either.
    let billingRetry: Bool?

    /// Whether **the calling user** is the one paying. Added by phase 113. Never another member's
    /// id — that is somebody else's UUID and does not belong in a response body.
    ///
    /// **Null means unknown, and unknown is not `false`.** `payer_user_id` is deliberately left null
    /// in exactly the two-guardian case, which is the only case where the question is meaningful,
    /// and the server cannot fix it: Apple's `appAccountToken` carries a *family* id, so no
    /// notification can ever name a user. Phase 113 shipped the read and recorded the rest in
    /// `blocked.md` §21.
    ///
    /// **So the Manage control shows on `true` and on nil, and hides only on an explicit `false`.**
    /// Hiding it on a null would strip a working control from a parent who is paying.
    let isPayer: Bool?

    /// **The union the server gates on since phase 121** — a receipt, an active grant, or a live
    /// trial. `tier` still means *what Apple said*; this is whether the archive is open.
    ///
    /// Optional for the same reason `billingRetry` is: a server predating the field sends no key,
    /// and a non-optional `Bool` would fail the whole decode. Carried so a client can read what the
    /// server actually decides on; nothing gates on it here yet.
    let entitled: Bool?

    /// `receipt` | `grant` | `trial` | `none`. **How a client tells complimentary from paid**, which
    /// `tier` and `access` together cannot: a granted household reads `access: "subscribed"` with
    /// `tier: "free"`, and the contract calls that pairing deliberate.
    ///
    /// A `String?` rather than an enum, as `plan` is and for the same reason — a value a later
    /// server invents must not fail the decode. Read it through `isGranted`.
    let entitlementSource: String?

    let guardians: [GuardianSummary]
    /// Only invites still acceptable. Accepted, revoked and expired ones are history.
    let pendingInvites: [InviteSummary]

    /// Somebody is paying Apple. **The only question Apple's management sheet answers**, and the
    /// only one a receipt submission proves — keep reading this where the subject is a receipt.
    var isSubscribed: Bool { tier == "subscribed" }

    /// Complimentary access from an admin grant. Not an Apple subscription: there is nothing in
    /// Apple's sheet to manage and, more to the point, nothing to sell.
    var isGranted: Bool { entitlementSource == "grant" }

    /// **A household a checkout would not serve** — paying Apple already, or granted everything a
    /// payment would buy. The buy button and the Settings upsell read this rather than `tier`,
    /// because a granted household keyed on `tier` was offered membership under a card that
    /// already said *Subscribed* (phase 141). A trial is deliberately *not* a member: the paywall
    /// exists to be shown to one.
    var isMember: Bool { isSubscribed || isGranted }

    /// `billingRetry`, with absent and `false` collapsed — which is every state that exists.
    /// **Nothing renders this yet**: there is no approved copy for the grace state, and a household
    /// in grace is fully entitled and correctly reads as subscribed either way.
    var isInBillingRetry: Bool { billingRetry ?? false }

    /// **Whether to offer Apple's subscription-management sheet.** True on an explicit `true` *and*
    /// on unknown — only a definite `false` hides it.
    ///
    /// The asymmetry is the whole point: `is_payer` is null in exactly the two-guardian case, and
    /// hiding the control on a null would strip a working affordance from a parent who is paying.
    var mayManageSubscription: Bool { isPayer != false }

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

    /// `POST /v1/families/me/transactions` — hand the server the transaction this device holds.
    ///
    /// Phase 140. The body is `Transaction.jwsRepresentation` verbatim; the server verifies it
    /// with the same Apple verifier the webhook uses and, if it proves an active subscription for
    /// *this* household, answers with the household already `subscribed`. **The answer is the
    /// `GET /v1/families/me` document**, so a caller settles on it exactly as it would on a read,
    /// and on nothing else (D5, D9). A `422` is a JWS Apple did not sign for this bundle; a `404` is
    /// a server that predates the route. Both, and a dropped connection, fall back to the poll that
    /// was already there. **A `409` (`.conflict`) is the one refusal a caller tells apart** (phase
    /// 143): the server will not attribute the receipt to this household — its `appAccountToken`
    /// names a different one, or the ledger already holds it for one — which is an answer the poll
    /// can never change, so `SubscriptionModel` says so rather than waiting out the window. A `409`
    /// without the envelope carries no code and is treated like the others.
    func submitTransaction(_ signedTransaction: String) async throws -> FamilySummary {
        let response: SubmittedTransactionResponse = try await send(
            .post, "v1/families/me/transactions",
            body: SubmitTransactionRequest(signedTransaction: signedTransaction)
        )
        return response.family
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
    /// ~~*`email` is optional and is only recorded — **nothing sends it**. The client delivers the
    /// link, which is why the caller presents a share sheet rather than a confirmation.*~~ —
    /// **struck Sep 2, 2026: the API's phase 136 mails it.** Give it an address and the server
    /// sends the invite; omit it and nothing is sent, which is still the in-person case. The raw
    /// token comes back either way, so the share sheet remains the fallback rather than the only
    /// route — and `emailQueued` on the response is what says which of the two just happened.
    ///
    /// A fourth refusal comes with the send: `.rateLimited` (429), reachable **only** when an
    /// address is given. The server mails a stranger's inbox on this route, so it is limited the
    /// way the sign-in link is.
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

// MARK: - Deleting the account

/// A scheduled deletion. `executeAfter` is what a confirmation reads back to the parent — the
/// client never computes it from a policy it would then have to keep in step with the server's.
nonisolated struct ScheduledDeletion: Decodable, Equatable, Sendable {
    let requestedAt: Date
    let executeAfter: Date
}

extension APIClient {

    /// `POST /v1/me/deletion` — ask for the account to be deleted, seven days from now.
    ///
    /// **`202`, and nothing is deleted yet.** Every refresh token is revoked, so this signs the
    /// account out of every device immediately — the caller must sign out, because the session
    /// is already dead server-side.
    ///
    /// **Idempotent:** asking twice returns the first request rather than restarting the clock.
    func requestAccountDeletion() async throws -> ScheduledDeletion {
        try await send(.post, "v1/me/deletion")
    }

    /// `DELETE /v1/me/deletion` — withdraw a request.
    ///
    /// **Kept for completeness rather than used by the app**, and that is worth knowing before
    /// somebody wires a button to it: requesting deletion revokes every refresh token, so within
    /// fifteen minutes the access token expires and there is no session left to call this with.
    /// **Signing in is the cancel a parent actually takes**, and the server does it for them.
    func cancelAccountDeletion() async throws {
        let _: EmptyResponse = try await send(.delete, "v1/me/deletion")
    }
}

// MARK: - Submitting a transaction (phase 140)

nonisolated private struct SubmitTransactionRequest: Encodable {
    let signedTransaction: String
}

/// `{ "status": "...", "family": { ... } }`. `status` is the server's own vocabulary
/// (`tier:subscribed`, `ignored:not-active`, …) and is carried for the log line only — nothing
/// here branches on it, because the household document is the only thing entitled to say
/// `subscribed`.
nonisolated struct SubmittedTransactionResponse: Decodable, Sendable {
    let status: String
    let family: FamilySummary
}
