import Foundation
import Testing

@testable import Rascal

/// Tapping an invitation link.
///
/// **`everyRefusalGetsItsOwnSentence` is the test that matters here.** The person on the other
/// end of this link may never have heard of Vellum — they were handed a URL by their spouse. A
/// generic error is a dead end for them: they cannot retry their way out of an expired
/// invitation, and "something went wrong" makes the other parent debug it.
@Suite("The invitation link")
struct InviteAcceptTests {

    private let host = "rascal-api.fly.dev"

    // MARK: Parsing

    @Test("a real invite link parses")
    func parsesAnInviteLink() throws {
        let url = try #require(URL(string: "https://rascal-api.fly.dev/invite/abc123"))
        #expect(InviteLink.parse(url, apiHost: host)?.token == "abc123")
    }

    @Test("a link from another host is refused")
    func refusesAnotherHost() throws {
        // iOS only hands the app links for domains it claims, so this is belt-and-braces — but
        // the same parser is reachable from anywhere in the process, and a token we are about to
        // POST should only ever have come from our own host.
        let url = try #require(URL(string: "https://evil.example.com/invite/abc123"))
        #expect(InviteLink.parse(url, apiHost: host) == nil)
    }

    @Test("http is refused even on the right host")
    func refusesPlainHTTP() throws {
        let url = try #require(URL(string: "http://rascal-api.fly.dev/invite/abc123"))
        #expect(InviteLink.parse(url, apiHost: host) == nil)
    }

    @Test("a claimed path with no token is not a link")
    func refusesAnEmptyToken() throws {
        // An empty token produces a request the server can only answer with 404, and a failure
        // the parent cannot act on.
        for raw in ["https://rascal-api.fly.dev/invite/", "https://rascal-api.fly.dev/invite"] {
            let url = try #require(URL(string: raw))
            #expect(InviteLink.parse(url, apiHost: host) == nil, "\(raw) should not parse")
        }
    }

    @Test("a nested path is not a token")
    func refusesANestedPath() throws {
        let url = try #require(URL(string: "https://rascal-api.fly.dev/invite/abc/def"))
        #expect(InviteLink.parse(url, apiHost: host) == nil)
    }

    @Test("a path that merely starts with the word invite is not claimed")
    func refusesAPrefixCollision() throws {
        // `/invite/` and not `/invite`: without the separator, `/invitations/x` would match.
        let url = try #require(URL(string: "https://rascal-api.fly.dev/invitations/abc123"))
        #expect(InviteLink.parse(url, apiHost: host) == nil)
    }

    @Test("a sign-in link is not an invitation, and vice versa")
    func theTwoLinkTypesDoNotOverlap() throws {
        let signIn = try #require(URL(string: "https://rascal-api.fly.dev/signin?token=abc"))
        let invite = try #require(URL(string: "https://rascal-api.fly.dev/invite/abc"))

        #expect(InviteLink.parse(signIn, apiHost: host) == nil)
        #expect(SignInLink.parse(invite, apiHost: host) == nil)
    }

    // MARK: What each failure means

    @Test("every refusal gets its own sentence rather than one generic error")
    func everyRefusalGetsItsOwnSentence() {
        // The server answers a single 404 for unknown, expired, revoked and already-used — on
        // purpose, because telling them apart would say whether a token ever existed. So this
        // is one state, and it is the one that says what to do next.
        #expect(
            InviteAcceptModel.classify(
                .api(code: .notFound, message: "Invite not found", field: nil, status: 404)
            ) == .noLongerValid
        )

        // The household filled up between the link being sent and this tap. Its own sentence:
        // nobody's mistake, and retrying cannot make it work.
        let full = InviteAcceptModel.classify(
            .api(code: .conflict, message: "This household already has two parents.",
                 field: nil, status: 409)
        )
        #expect(full == .refused("This household already has two parents."))

        // The network, not the invitation — and the only state that earns a retry.
        if case .unreachable = InviteAcceptModel.classify(.transport("offline")) {} else {
            Issue.record("a transport failure should be unreachable, not a dead invitation")
        }
    }

    @Test("a signed-out session is not reported as a broken invitation")
    func signedOutIsNotABrokenLink() {
        // Two different problems with two different fixes. Folding them together would tell
        // somebody to ask for a new link when the link was fine.
        for error in [
            APIError.sessionExpired,
            .api(code: .unauthenticated, message: "x", field: nil, status: 401),
        ] {
            #expect(InviteAcceptModel.classify(error) != .noLongerValid)
        }
    }

    @Test("only the unreachable state offers a retry")
    func onlyUnreachableIsRetryable() {
        // A retry on an expired invitation is a button that cannot work, which teaches the
        // parent that the screen is decorative.
        let dead = InviteAcceptModel.classify(
            .api(code: .notFound, message: "x", field: nil, status: 404)
        )
        if case .unreachable = dead {
            Issue.record("a dead invitation must not offer a retry")
        }
    }
}
