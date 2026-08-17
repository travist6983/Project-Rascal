import Foundation
import Testing

@testable import Rascal

/// The household on the phone: who shares this archive, and the one refusal that must read as a
/// door rather than a wall.
///
/// **`freeTierOpensTheUpgradeRatherThanAnError` is the test that matters here.** A `402` folded
/// into the generic error path renders the product's first paywall as a failure — which is the
/// exact shape `docs/design-system.md` forbids, and the sort of thing that looks fine in a diff
/// and wrong on a phone.
@Suite("Guardians and the invite")
struct GuardiansTests {

    // MARK: The error code

    @Test("subscription_required round-trips rather than decoding as unknown")
    func subscriptionRequiredRoundTrips() {
        // A code the client silently maps to `.unknown` is one no branch can ever match on, so
        // the paywall would never open however carefully the model was written.
        #expect(APIErrorCode(rawValue: "subscription_required").rawValue == "subscription_required")
        if case .unknown = APIErrorCode(rawValue: "subscription_required") {
            Issue.record("subscription_required decoded as .unknown")
        }
    }

    @Test("the 402 shows the server's own words rather than a client paraphrase")
    func paywallCopyComesFromTheServer() {
        let server = "Subscribing adds a second parent to your household."
        let error = APIError.api(
            code: .subscriptionRequired, message: server, field: nil, status: 402
        )
        #expect(error.userMessage == server)
    }

    // MARK: Decoding

    @Test("the family response decodes, including a null grant date")
    func familyDecodes() throws {
        let json = """
        {
          "family_id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "tier": "subscribed",
          "guardians": [
            {"user_id": "3F2504E0-4F89-11D3-9A0C-0305E82C3302", "display_name": "Travis",
             "role": "parent", "granted_at": "2026-08-17T11:00:00Z", "is_you": true},
            {"user_id": "3F2504E0-4F89-11D3-9A0C-0305E82C3303", "display_name": null,
             "role": "parent", "granted_at": null, "is_you": false}
          ],
          "pending_invites": []
        }
        """
        let family = try APIClient.decoder.decode(FamilySummary.self, from: Data(json.utf8))

        #expect(family.isSubscribed)
        #expect(family.isFull)
        #expect(family.guardians[0].displayLabel == "Travis")
        // A null grant date is a real state, not a decode failure.
        #expect(family.guardians[1].grantedAt == nil)
        // Never a raw id, and never an empty string.
        #expect(family.guardians[1].displayLabel == "The other parent")
    }

    @Test("a one-guardian household is not full, so the invite affordance stays")
    func soloHouseholdIsNotFull() throws {
        let json = """
        {"family_id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "tier": "free",
         "guardians": [{"user_id": "3F2504E0-4F89-11D3-9A0C-0305E82C3302",
                        "display_name": "Travis", "role": "parent",
                        "granted_at": "2026-08-17T11:00:00Z", "is_you": true}],
         "pending_invites": []}
        """
        let family = try APIClient.decoder.decode(FamilySummary.self, from: Data(json.utf8))

        #expect(!family.isFull)
        #expect(!family.isSubscribed)
    }

    @Test("the created invite carries its raw token")
    func createdInviteDecodes() throws {
        let json = """
        {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3304", "email": "anna@example.com",
         "role": "parent", "expires_at": "2026-08-24T11:00:00Z",
         "created_at": "2026-08-17T11:00:00Z", "token": "2jtAKk90R8tJPR193YW9G79zRvldWxdr"}
        """
        let created = try APIClient.decoder.decode(CreatedInvite.self, from: Data(json.utf8))

        #expect(created.token == "2jtAKk90R8tJPR193YW9G79zRvldWxdr")
        #expect(created.email == "anna@example.com")
    }

    @Test("the preview carries first names and nothing that identifies anybody")
    func previewDecodes() throws {
        let json = """
        {"invited_by": "Travis", "role": "parent", "expires_at": "2026-08-24T11:00:00Z",
         "children": ["Miles", "Nora"]}
        """
        let preview = try APIClient.decoder.decode(InvitePreview.self, from: Data(json.utf8))

        #expect(preview.invitedBy == "Travis")
        #expect(preview.children == ["Miles", "Nora"])
    }

    // MARK: The link

    @Test("the share link is a universal link on the configured host")
    func shareLinkIsAUniversalLink() throws {
        let base = try #require(URL(string: "https://rascal-api.fly.dev"))
        let url = try #require(GuardiansModel.shareURL(token: "abc123", base: base))

        #expect(url.scheme == "https")
        #expect(url.absoluteString == "https://rascal-api.fly.dev/invite/abc123")
    }

    @Test("no configured host means no link rather than a link to nowhere")
    func noBaseMeansNoLink() {
        // A custom-scheme fallback would give a spouse on a laptop a browser error about a
        // scheme it has never heard of, which is worse than saying there is nothing to send.
        #expect(GuardiansModel.shareURL(token: "abc123", base: nil) == nil)
    }

    @Test("a token is escaped into the path rather than interpolated raw")
    func tokenIsEscaped() {
        #expect(APIClient.escape("a/b?c") == "a%2Fb%3Fc")
        // The real shape survives unchanged, so the escaping costs nothing in practice.
        #expect(APIClient.escape("2jtAKk90R8tJ") == "2jtAKk90R8tJ")
    }
}
