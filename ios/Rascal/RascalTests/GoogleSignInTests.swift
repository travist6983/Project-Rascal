import CryptoKit
import Foundation
import Testing

@testable import Rascal

/// Google sign-in: the PKCE flow, and the two checks that make it safe to run in a browser.
///
/// **PKCE is what stands in for the client secret an iOS OAuth client does not have.** The
/// authorization code comes back over a custom URL scheme, which any app on the device can
/// claim — so the code alone must be worthless. These tests pin the two things that make it so:
/// the challenge is a real S256 hash of the verifier, and the verifier is the only thing that
/// redeems the code.
///
/// The `state` check matters for the mirror-image reason: without it, a callback somebody else
/// started would attach *their* Google account to *this* device.
@Suite("Google sign-in")
struct GoogleSignInTests {

    static let config = GoogleOAuthConfig(
        clientID: "1234-abc.apps.googleusercontent.com",
        reversedClientID: "com.googleusercontent.apps.1234-abc"
    )

    // MARK: PKCE

    @Test("the challenge is a real S256 hash of the verifier, base64url and unpadded")
    func challengeIsS256() {
        let pkce = PKCEChallenge(verifier: "a-known-verifier")

        let expected = Data(SHA256.hash(data: Data("a-known-verifier".utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(pkce.challenge == expected)
        #expect(pkce.method == "S256")
        // `plain` would make PKCE decorative — the challenge would *be* the verifier, and an
        // attacker who read the authorization request could redeem the code.
        #expect(pkce.challenge != pkce.verifier)
    }

    @Test("base64url never emits characters that mean something else in a query string")
    func base64URLIsQuerySafe() {
        // +, / and = all have meaning in a query string, and Google rejects a challenge
        // carrying them. This byte pattern produces all three under plain base64.
        let encoded = Data([251, 255, 190, 0]).base64URLEncodedString()

        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test("a generated verifier is long enough to be unguessable")
    func verifierLength() {
        let pkce = PKCEChallenge()
        // RFC 7636 allows 43…128. 32 random bytes base64url-encode to exactly 43.
        #expect(pkce.verifier.count >= 43)
        #expect(pkce.verifier.count <= 128)
        #expect(PKCEChallenge().verifier != pkce.verifier)
    }

    // MARK: The authorization request

    @Test("the authorization URL asks for identity only, with the challenge and no secret")
    func authorizationURL() throws {
        let pkce = PKCEChallenge(verifier: "v")
        let url = GoogleSignInFlow.authorizationURL(config: Self.config, pkce: pkce, state: "st")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(query["client_id"] == Self.config.clientID)
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "st")
        #expect(query["redirect_uri"] == "com.googleusercontent.apps.1234-abc:/oauth2redirect")

        // **Identity only, and this assertion is the guard on it.** A Drive or Gmail scope would
        // make Google verification mandatory, and neither is anything this product does.
        #expect(query["scope"] == "openid email profile")

        // A public client has no secret, and one appearing in a URL would be worse than useless.
        #expect(query["client_secret"] == nil)
        // Never requested: we hold no Google scopes worth calling later, and a refresh token we
        // do not use is a credential to lose.
        #expect(query["access_type"] != "offline")
    }

    // MARK: The callback

    @Test("a callback whose state does not match is refused before the code is read")
    func stateMismatchIsRefused() async {
        // The authorizer answers with a well-formed callback carrying somebody else's state.
        let flow = GoogleSignInFlow(
            config: Self.config,
            authorizer: GoogleCallbackAuthorizer { _ in
                URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=stolen&state=not-ours")!
            },
            exchange: { _ in
                Issue.record("the token endpoint must not be reached on a state mismatch")
                return (Data(), URLResponse())
            }
        )

        await #expect(throws: GoogleSignInError.stateMismatch) { try await flow.run() }
    }

    @Test("a callback with no code is refused")
    func missingCodeIsRefused() async {
        let flow = GoogleSignInFlow(
            config: Self.config,
            authorizer: EchoStateAuthorizer { state in
                URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?state=\(state)")!
            },
            exchange: { _ in (Data(), URLResponse()) }
        )

        await #expect(throws: GoogleSignInError.noAuthorizationCode) { try await flow.run() }
    }

    @Test("cancelling surfaces as .cancelled so the caller can stay silent")
    func cancellation() async {
        let flow = GoogleSignInFlow(
            config: Self.config,
            authorizer: ThrowingAuthorizer(GoogleSignInError.cancelled),
            exchange: { _ in (Data(), URLResponse()) }
        )

        await #expect(throws: GoogleSignInError.cancelled) { try await flow.run() }
    }

    // MARK: The token exchange

    @Test("the exchange sends the verifier and no client secret, and returns the id_token")
    func exchangeSendsVerifier() async throws {
        let seen = LockedBox<String>()
        let flow = GoogleSignInFlow(
            config: Self.config,
            authorizer: EchoStateAuthorizer { state in
                URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=abc&state=\(state)")!
            },
            exchange: { request in
                seen.set(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
                let body = Data(#"{"id_token":"the-id-token","access_token":"dropped"}"#.utf8)
                return (body, HTTPURLResponse(
                    url: GoogleOAuthConfig.tokenEndpoint,
                    statusCode: 200, httpVersion: nil, headerFields: nil
                )!)
            }
        )

        let exchange = try await flow.run()

        #expect(exchange.identityToken == "the-id-token")
        let sent = try #require(seen.value)
        #expect(sent.contains("code_verifier="))
        #expect(sent.contains("grant_type=authorization_code"))
        #expect(!sent.contains("client_secret"))
    }

    @Test("a token response with no id_token is refused rather than half-accepted")
    func missingIdentityToken() async {
        let flow = GoogleSignInFlow(
            config: Self.config,
            authorizer: EchoStateAuthorizer { state in
                URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=abc&state=\(state)")!
            },
            exchange: { _ in
                // An access token is not an identity. Accepting this would send the server
                // something it cannot verify as a person.
                let body = Data(#"{"access_token":"only-this"}"#.utf8)
                return (body, HTTPURLResponse(
                    url: GoogleOAuthConfig.tokenEndpoint,
                    statusCode: 200, httpVersion: nil, headerFields: nil
                )!)
            }
        )

        await #expect(throws: GoogleSignInError.noIdentityToken) { try await flow.run() }
    }

    @Test("a non-2xx from the token endpoint is a transport failure, not a sign-in")
    func tokenEndpointError() async {
        let flow = GoogleSignInFlow(
            config: Self.config,
            authorizer: EchoStateAuthorizer { state in
                URL(string: "com.googleusercontent.apps.1234-abc:/oauth2redirect?code=abc&state=\(state)")!
            },
            exchange: { _ in
                (Data(#"{"error":"invalid_grant"}"#.utf8), HTTPURLResponse(
                    url: GoogleOAuthConfig.tokenEndpoint,
                    statusCode: 400, httpVersion: nil, headerFields: nil
                )!)
            }
        )

        await #expect(throws: GoogleSignInError.transport) { try await flow.run() }
    }

    // MARK: Configuration

    @Test("a build with no client id produces no config, so the button can hide")
    func absentConfiguration() {
        #expect(GoogleOAuthConfig(bundle: EmptyBundle()) == nil)
    }

    @Test("the redirect uri is built from the reversed client id")
    func redirectURI() {
        // The scheme half has to match `CFBundleURLSchemes` exactly or the browser closes onto
        // nothing and the app never hears back — a failure with no error anywhere.
        #expect(Self.config.redirectURI.hasPrefix(Self.config.reversedClientID + ":"))
    }

    @Test("only the id_token is decoded off the token response")
    func tokenResponseDecoding() throws {
        let json = Data(#"{"id_token":"abc","access_token":"xyz","refresh_token":"never"}"#.utf8)
        let decoded = try JSONDecoder().decode(GoogleTokenResponse.self, from: json)
        #expect(decoded.idToken == "abc")
    }
}

// MARK: - Stubs

private struct GoogleCallbackAuthorizer: GoogleAuthorizing {
    let callback: @Sendable (URL) -> URL
    func authorize(url: URL, callbackScheme: String) async throws -> URL { callback(url) }
}

/// Reflects the `state` the flow generated back into the callback, so a test can exercise the
/// happy path without knowing a value the flow makes up internally.
private struct EchoStateAuthorizer: GoogleAuthorizing {
    let build: @Sendable (String) -> URL

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        return build(state)
    }
}

private struct ThrowingAuthorizer: GoogleAuthorizing {
    let error: GoogleSignInError
    init(_ error: GoogleSignInError) { self.error = error }
    func authorize(url: URL, callbackScheme: String) async throws -> URL { throw error }
}

private final class EmptyBundle: Bundle, @unchecked Sendable {
    override func object(forInfoDictionaryKey key: String) -> Any? { nil }
}

/// A tiny thread-safe box, so a `@Sendable` closure can hand a value back to the test.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        lock.withLock { stored }
    }

    func set(_ newValue: T) {
        lock.withLock { stored = newValue }
    }
}

// MARK: - Phase 82: the name in every system dialog, and the browser session's one decision

/// The alert a parent sees at sign-in reads *"Vellum" Wants to Use "accounts.google.com" to Sign In*,
/// and there is no API to change what that alert calls the app — it reads the name out of the bundle.
/// So the name is not a sign-in concern at all; it is the bundle leaking into every sentence iOS
/// writes about this app.
///
/// **Phase 82 named the wrong key, and this suite went on passing while the alert said "Rascal".**
/// The comment here asserted the alert reads `CFBundleDisplayName` — which phase 73 had already set
/// to "Vellum" in all four plists, which is why nobody looked again. It reads **`CFBundleName`**, and
/// that key was still `$(PRODUCT_NAME)`: the Xcode target name, a build artefact. A parent tapping
/// *Continue with Google* was asked to trust an app called "Rascal", on the one dialog whose whole
/// job is to establish that the app asking is the app they installed.
///
/// **Phase 114, Aug 23, 2026, and settled by experiment rather than by reading.** A throwaway
/// simulator app set `CFBundleDisplayName`, `CFBundleName` and its executable name to three
/// different strings and started an `ASWebAuthenticationSession`; the alert rendered the
/// `CFBundleName` one. There are **two** name keys, they are not interchangeable, and a rename has
/// to move both in all four plists.
@MainActor
@Suite("Phase 82 — the name in system dialogs")
struct BundleDisplayNameTests {

    @Test("the app's display name is the product name, not the codename or the target name")
    func displayNameIsVellum() throws {
        // Unit tests run in the app's host process, so `Bundle.main` here is the app bundle — which
        // makes this the built artefact's own answer rather than a re-reading of the source plist.
        // That distinction is the whole point: a doc claimed this was "verified out of the built
        // bundles" on Aug 12, for a name that has changed twice since.
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String

        #expect(name == "Vellum")
        // The codename and the Xcode target name are the two things that have actually leaked here.
        #expect(name != "Rascal", "the codename reached every system alert for as long as it was set")
        #expect(name != "Dogear", "superseded Aug 17, 2026")
    }

    /// **Phase 114. The assertion the test above was believed to be making.**
    ///
    /// `CFBundleName` is what `ASWebAuthenticationSession` puts in its consent alert, and it is a
    /// different string from the one under the icon. Read from `Bundle.main` for the same reason the
    /// test above is: unit tests run in the app's host process, so this is the built artefact's own
    /// answer and not a re-reading of the source plist that produced it.
    @Test("the bundle name — the string the sign-in alert actually reads — is the product name")
    func bundleNameIsVellum() throws {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String

        #expect(name == "Vellum")
        #expect(
            name != "Rascal",
            "the target name is what the Google sign-in alert asked a parent to trust until Aug 23"
        )
        #expect(name != "Dogear", "superseded Aug 17, 2026")
    }

    /// **Phase 114. The two tests above can only see the app.**
    ///
    /// `Bundle.main` in a unit test is the host app, so the widget's and the share extension's
    /// plists are invisible to it — and those are two more bundles iOS writes sentences about. This
    /// reads all four from source and pins both keys in each, as literals: a `$(PRODUCT_NAME)`
    /// left in any of them resolves to a target name — "Rascal", "RascalWidget", "RascalShare" —
    /// and parses as that string here, so this fails on the exact defect rather than on its shape.
    @Test("all four plists carry both name keys, literally")
    func everyPlistCarriesBothNamesLiterally() throws {
        // `ios/Rascal`, resolved from this file so the scan survives Xcode, xcodebuild and CI.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()

        for file in ["Info.plist", "Info-Debug.plist", "RascalWidget-Info.plist", "RascalShare-Info.plist"] {
            let data = try Data(contentsOf: root.appendingPathComponent(file))
            let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
            let plist = parsed as? [String: Any]

            for key in ["CFBundleName", "CFBundleDisplayName"] {
                let value = plist?[key] as? String
                #expect(
                    value == "Vellum",
                    "\(file) declares \(key) as \(value ?? "nothing"); iOS renders it to a parent"
                )
            }
        }
    }
}

/// One decision, named so it can be asserted and so a future change happens once, on purpose.
@Suite("Phase 82 — the browser session stays shared, deliberately")
struct EphemeralSessionDecisionTests {

    /// **This test exists to make a rejection explicit, not to lock a value forever.**
    ///
    /// Flipping it to `true` would suppress the sign-in alert — believed, not observed. Against
    /// that: an ephemeral session drops the account picker for a parent with two Google accounts,
    /// and drops the cookie that makes a second sign-in one tap. Those two are established. The
    /// suppression is not. If somebody verifies it on a device and takes the trade, this test is
    /// the thing that has to change with it, which is the point.
    @Test("the Google flow uses a shared browser session, and that is a recorded decision")
    func sessionIsNotEphemeral() {
        #expect(LiveGoogleAuthorizer.prefersEphemeralSession == false)
    }
}
