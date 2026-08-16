import CryptoKit
import Foundation
import Testing

@testable import Rascal

/// The client-side fixes from the pre-merge review of phases 55 and 58.
///
/// **`aMagicLinkNeverSilentlySwapsAnAccount` is the one that matters.** The others are
/// robustness; that one was a data-exfiltration hole wearing a sign-in bug's clothes.
@Suite("Auth hardening")
struct AuthHardeningTests {

    // MARK: The universal link's host

    @Test("a sign-in link from another host is refused")
    func foreignHostRefused() {
        // iOS only hands the app links for domains it claims, so this is belt-and-braces —
        // but the parser is reachable from anywhere in the process, and a token bound for our
        // `/auth/email/complete` should only ever have come from our own host.
        let evil = URL(string: "https://rascal-api.fly.dev.attacker.test/signin?token=abc")!
        #expect(SignInLink.parse(evil, apiHost: "rascal-api.fly.dev") == nil)

        let lookalike = URL(string: "https://evil.test/signin?token=abc")!
        #expect(SignInLink.parse(lookalike, apiHost: "rascal-api.fly.dev") == nil)
    }

    @Test("the real host still parses, case-insensitively")
    func realHostParses() {
        let url = URL(string: "https://Rascal-API.fly.dev/signin?token=abc")!
        #expect(SignInLink.parse(url, apiHost: "rascal-api.fly.dev") == SignInLink(token: "abc"))
    }

    @Test("an unreadable configuration leaves the host check inert rather than failing closed")
    func absentHostIsInert() {
        // A build with no API_BASE_URL should not have every sign-in link silently stop
        // working — the entitlement is still the real gate.
        let url = URL(string: "https://anything.test/signin?token=abc")!
        #expect(SignInLink.parse(url, apiHost: nil) == SignInLink(token: "abc"))
    }

    // MARK: PKCE entropy

    @Test("two verifiers are never the same, and never a known constant")
    func verifierEntropy() {
        // The failure this guards is specific: a discarded `SecRandomCopyBytes` status leaves
        // the buffer all zeroes, which produces an identical verifier and an identical `state`
        // on every device — PKCE with no secret in it, and a CSRF token that never varies.
        let verifiers = Set((0..<50).map { _ in PKCEChallenge().verifier })
        #expect(verifiers.count == 50)

        let allZero = Data(repeating: 0, count: 32).base64URLEncodedString()
        #expect(!verifiers.contains(allZero))
    }

    @Test("the challenge still hashes whatever verifier it was given")
    func challengeFollowsVerifier() {
        let pkce = PKCEChallenge()
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString()
        #expect(pkce.challenge == expected)
    }
}
