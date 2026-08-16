import Foundation
import Testing

@testable import Rascal

/// The credentials list, the magic link, and the one refusal that must not read as an error.
///
/// **`lastCredentialReadsAsCareNotFailure` is the test that matters here.** Removing a sign-in
/// method is the only action in this app that could lock a parent out of eighteen years of their
/// child's life. The server refuses; the client's job is to make that refusal sound like the app
/// looking after them rather than something they did wrong.
@Suite("Credentials and the magic link")
struct CredentialsTests {

    // MARK: The universal link

    @Test("a well-formed sign-in link yields its token")
    func linkParses() throws {
        // The host is stated explicitly because this test is about *parsing*. Left to the
        // default it would read `API_BASE_URL`, which in a test build is localhost — so this
        // would exercise the host check rather than the thing it is named for. The host policy
        // itself is covered in `AuthHardeningTests`.
        let url = URL(string: "https://rascal-api.fly.dev/signin?token=abc123")!
        #expect(SignInLink.parse(url, apiHost: "rascal-api.fly.dev") == SignInLink(token: "abc123"))
    }

    @Test("only the one claimed path is a sign-in link")
    func linkPathIsNarrow() {
        // The app claims `/signin` and nothing else. Claiming `*` on the API host would make it
        // intercept /health, presigned media URLs, and anything a browser client ever serves.
        for path in ["/health", "/v1/entries", "/", "/signin/extra"] {
            let url = URL(string: "https://rascal-api.fly.dev\(path)?token=abc")!
            #expect(
                SignInLink.parse(url, apiHost: "rascal-api.fly.dev") == nil,
                "\(path) must not parse as a sign-in link"
            )
        }
    }

    @Test("a custom-scheme URL is not a sign-in link")
    func linkRequiresHTTPS() {
        // The widget's deep links arrive on `childarchive://`. The two paths must not cross:
        // one assumes a session exists, the other exists to create one.
        let url = URL(string: "childarchive://signin?token=abc")!
        #expect(SignInLink.parse(url) == nil)
    }

    @Test("a link with no token is refused rather than sent as an empty one")
    func linkRequiresToken() {
        // An empty token produces a request the server can only answer 401 — a failure the
        // parent can do nothing about, from a tap that looked legitimate.
        for query in ["", "?token=", "?other=abc"] {
            let url = URL(string: "https://rascal-api.fly.dev/signin\(query)")!
            #expect(SignInLink.parse(url, apiHost: "rascal-api.fly.dev") == nil)
        }
    }

    @Test("the widget's deep links still parse, unchanged")
    func widgetLinksUnaffected() {
        let url = URL(string: "childarchive://today")!
        #expect(WidgetDeepLink.parse(url) == .today)
        #expect(SignInLink.parse(url) == nil)
    }

    // MARK: The copy on the one refusal that counts

    @Test("the last-credential refusal reads as care, not as failure")
    func lastCredentialReadsAsCareNotFailure() {
        let error = APIError.api(
            code: .lastCredential,
            message: "This is the only way left to sign in to this account, so it cannot be removed.",
            field: nil,
            status: 409
        )

        let shown = CredentialsModel.explainRemove(error)

        // Says what to do next.
        #expect(shown.contains("Add another one first"))
        // And none of the vocabulary the tone rules forbid.
        for forbidden in ["Error", "error", "Failed", "failed", "can't", "cannot", "Sorry"] {
            #expect(!shown.contains(forbidden), "the refusal must not say \(forbidden)")
        }
    }

    @Test("an address already on another account says so plainly")
    func credentialInUseCopy() {
        let error = APIError.api(code: .credentialInUse, message: "raw", field: nil, status: 409)
        #expect(CredentialsModel.explainAdd(error).contains("different account"))
    }

    @Test("the four phase 51-57 error codes round-trip")
    func newErrorCodes() {
        // Decoded from the wire and written back identically — a code the client silently maps
        // to `.unknown` is one no branch can ever match on.
        for raw in ["credential_in_use", "last_credential", "rate_limited", "sign_in_link_invalid"] {
            #expect(APIErrorCode(rawValue: raw).rawValue == raw)
            if case .unknown = APIErrorCode(rawValue: raw) {
                Issue.record("\(raw) decoded as .unknown")
            }
        }
    }

    @Test("an expired link says to ask for another rather than blaming the parent")
    func expiredLinkCopy() {
        let error = APIError.api(code: .signInLinkInvalid, message: "raw", field: nil, status: 401)
        let shown = error.userMessage
        #expect(shown.contains("new one"))
        #expect(!shown.contains("Error"))
    }

    // MARK: The list

    @Test("a pending email credential is not the same as a removed one")
    func pendingIsNotRevoked() throws {
        // The server reuses `revoked_at` for "removed" and "not verified yet" because the
        // meaning it needs to convey is identical — *not a way in*. The difference matters only
        // to the copy, and only for email.
        let pending = try decode(provider: "email", revoked: true)
        let removed = try decode(provider: "apple", revoked: true)
        let live = try decode(provider: "apple", revoked: false)

        #expect(pending.isPending)
        #expect(!removed.isPending)
        #expect(!live.isPending)
        #expect(!pending.isActive)
        #expect(live.isActive)
    }

    @Test("a provider this build has never heard of still renders")
    func unknownProviderRenders() throws {
        // Hiding it would hide a way into the account from the person who owns it.
        #expect(try decode(provider: "okta", revoked: false).displayName == "Okta")
    }

    @Test("the list model never exposes a raw subject id, because the server never sends one")
    func noRawSubject() throws {
        let summary = try decode(provider: "apple", revoked: false)
        #expect(summary.subjectHint == "••••cdef")
        // There is no `subjectId` on the type at all — the compiler is the assertion here, and
        // this line documents why it must stay that way.
        #expect(!summary.subjectHint.contains("001."))
    }

    private func decode(provider: String, revoked: Bool) throws -> CredentialSummary {
        let json = """
        {
          "id": "8B2F0A4E-0000-4000-8000-000000000001",
          "provider": "\(provider)",
          "subject_hint": "••••cdef",
          "created_at": "2026-08-16T12:00:00Z",
          "revoked_at": \(revoked ? "\"2026-08-16T13:00:00Z\"" : "null")
        }
        """
        return try APIClient.decoder.decode(CredentialSummary.self, from: Data(json.utf8))
    }
}
