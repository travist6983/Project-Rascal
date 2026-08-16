import AuthenticationServices
import CryptoKit
import Foundation

/// Google sign-in, reduced to the one value RASCAL actually needs: an `id_token`.
///
/// The same shape as `AppleSignIn.swift`, and for the same reason — `ASWebAuthenticationSession`
/// cannot be constructed in a test, so it lives behind `GoogleAuthorizing` and everything above
/// this seam takes plain `Sendable` structs.
///
/// **`ASWebAuthenticationSession` + PKCE rather than the GoogleSignIn SDK, and that was not a
/// close call.** `ios/CLAUDE.md` rule 4 forbids SPM packages outright, so the SDK was never
/// available; the trade it would have bought — less code for one more dependency and a
/// third-party privacy manifest — is the wrong side of the trade for an app whose promise is
/// that a child's record does not leave.
///
/// **What this flow is not doing is as important as what it is.** It asks for `openid email
/// profile` and nothing else, it never requests offline access, and it therefore never receives
/// or stores a Google refresh token. Google is identity at the moment of sign-in and nothing
/// afterwards: the session that survives is ours, minted by `POST /v1/auth/google`.

// MARK: - Configuration

/// The client id, read from `Info.plist` per rule 5 — never hardcoded in Swift.
///
/// Not a secret. An iOS OAuth client is a *public* client: Google issues no client secret for
/// one, which is exactly why the flow has to be PKCE, and the id ships inside every copy of the
/// app regardless.
nonisolated struct GoogleOAuthConfig: Equatable, Sendable {
    let clientID: String
    /// The client id with its components reversed, which is the custom URL scheme the callback
    /// comes back on. Registered in `Info.plist`'s `CFBundleURLTypes`; if the two ever disagree
    /// the browser closes onto nothing and the app never hears back.
    let reversedClientID: String

    var redirectURI: String { "\(reversedClientID):/oauth2redirect" }

    /// Identity only. **Never widen this.** A Drive, Calendar or Gmail scope would make Google
    /// verification mandatory and turn a free, instant setup into a review queue — and none of
    /// them is anything this product does.
    static let scope = "openid email profile"

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    init(clientID: String, reversedClientID: String) {
        self.clientID = clientID
        self.reversedClientID = reversedClientID
    }

    /// Returns nil when the app was built without a Google client id, which is a real state —
    /// the repository shipped without one for a while. The caller hides the button rather than
    /// offering one that cannot work.
    init?(bundle: Bundle = .main) {
        guard let clientID = bundle.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
              let reversed = bundle.object(forInfoDictionaryKey: "GOOGLE_REVERSED_CLIENT_ID") as? String,
              !clientID.isEmpty, !reversed.isEmpty
        else { return nil }
        self.init(clientID: clientID, reversedClientID: reversed)
    }
}

// MARK: - PKCE

/// A PKCE verifier and its S256 challenge.
///
/// **PKCE is what replaces the client secret this client does not have.** The verifier is kept
/// in memory for the length of one sign-in and sent only on the token exchange, so an attacker
/// who intercepts the authorization code on the custom-scheme callback still cannot redeem it.
nonisolated struct PKCEChallenge: Equatable, Sendable {
    let verifier: String
    let challenge: String
    let method = "S256"

    init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    /// 32 random bytes, base64url-encoded to 43 characters — the low end of RFC 7636's 43…128,
    /// and 256 bits of entropy.
    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // **Checked rather than discarded.** On failure the buffer stays all zeroes, which
        // would produce an identical verifier and an identical `state` on every device — a
        // PKCE exchange with no secret in it and a CSRF token that never varies. The fallback
        // is two UUIDs, which are not a CSPRNG but are unpredictable enough to be worth far
        // more than a known constant.
        if status != errSecSuccess {
            let fallback = UUID().uuidString + UUID().uuidString
            self.init(verifier: Data(fallback.utf8).base64URLEncodedString())
            return
        }
        self.init(verifier: Data(bytes).base64URLEncodedString())
    }
}

nonisolated extension Data {
    /// base64url, unpadded. Plain base64 is not interchangeable here: `+`, `/` and `=` all have
    /// meaning in a query string, and Google rejects a challenge carrying them.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - What comes back

/// The one value the server needs. Everything else Google returns is deliberately dropped.
nonisolated struct GoogleExchange: Equatable, Sendable {
    let identityToken: String
    let displayName: String?
}

/// The request body for `POST /v1/auth/google`.
nonisolated struct GoogleSignInRequest: Encodable {
    let identityToken: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case identityToken, displayName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identityToken, forKey: .identityToken)
        // Absent rather than null, the same rule Apple's request follows: the server gap-fills
        // first-non-null-wins and an empty string would occupy the field permanently.
        try container.encodeIfPresent(displayName, forKey: .displayName)
    }
}

nonisolated enum GoogleSignInError: Error, Equatable {
    /// The parent closed the sheet. **Not an error to report** — cancelling is a decision, and
    /// saying anything about it would be the app arguing with someone who just said no.
    case cancelled
    case notConfigured
    /// The callback came back without the code, or with an `error=` parameter.
    case noAuthorizationCode
    /// `state` did not match what we sent. Someone else's callback, or a replayed one.
    case stateMismatch
    /// Google's token endpoint answered, but without an `id_token`.
    case noIdentityToken
    case transport
}

// MARK: - The browser seam

/// Presents the authorization URL and returns the callback URL.
///
/// A protocol so the whole flow above it can be tested without a browser — the same seam
/// `AppleCredentialChecking` provides for `getCredentialState`.
nonisolated protocol GoogleAuthorizing: Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}

nonisolated struct LiveGoogleAuthorizer: GoogleAuthorizing {
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        // **The session is held for the length of the flow, deliberately.**
        // `ASWebAuthenticationSession` is not retained by the system once `start()` returns;
        // as a bare local it could deallocate immediately, and the symptom is not a crash but
        // a browser sheet that never calls back — leaving `isWorking` true and every sign-in
        // button disabled until the app is relaunched.
        let holder = SessionHolder()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callback, error in
                defer { holder.session = nil }
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? GoogleSignInError.cancelled : .transport)
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: GoogleSignInError.noAuthorizationCode)
                    return
                }
                continuation.resume(returning: callback)
            }
            // **False deliberately.** An ephemeral session would mean a parent with two Google
            // accounts could never see the picker, and it would also drop the session cookie
            // that makes a second sign-in a single tap. Nothing about this archive is stored in
            // Google's cookie jar.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = PresentationAnchor.shared
            holder.session = session
            if !session.start() {
                holder.session = nil
                continuation.resume(throwing: GoogleSignInError.transport)
            }
        }
    }
}

/// Keeps the in-flight session alive until its completion handler runs.
private nonisolated final class SessionHolder: @unchecked Sendable {
    // The module defaults to main-actor isolation and this is written from the framework's
    // nonisolated completion handler, so the type is explicitly nonisolated. A lock rather
    // than bare mutation because those two contexts are genuinely different threads.
    private let lock = NSLock()
    private var stored: ASWebAuthenticationSession?

    var session: ASWebAuthenticationSession? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// `ASWebAuthenticationSession` needs a window to present from, and will not start without one.
///
/// **Nonisolated, with the hop inside the one method that needs it.** The framework calls
/// `presentationAnchor(for:)` from a nonisolated context, so a `@MainActor` type here is an
/// error in Swift 6 language mode rather than a safety win — and `session.start()` is already
/// only ever reached from the main actor.
private nonisolated final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    // The `@unchecked Sendable` conformance is what lets this be reached from the framework's
    // nonisolated callback without an isolation warning. Safe because the instance is immutable
    // and holds nothing — it exists only to answer with a window.
    static let shared = PresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}

// MARK: - The flow

/// Runs the authorization-code-with-PKCE flow and hands back an `id_token`.
nonisolated struct GoogleSignInFlow: Sendable {
    let config: GoogleOAuthConfig
    let authorizer: GoogleAuthorizing
    /// Injected so the token exchange can be stubbed. Defaults to a plain ephemeral session —
    /// this call carries no credential of ours and must not share cookies with the API client.
    let exchange: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        config: GoogleOAuthConfig,
        authorizer: GoogleAuthorizing = LiveGoogleAuthorizer(),
        exchange: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.config = config
        self.authorizer = authorizer
        self.exchange = exchange ?? { request in
            try await URLSession(configuration: .ephemeral).data(for: request)
        }
    }

    func run() async throws -> GoogleExchange {
        let pkce = PKCEChallenge()
        let state = PKCEChallenge().verifier

        let callback = try await authorizer.authorize(
            url: Self.authorizationURL(config: config, pkce: pkce, state: state),
            callbackScheme: config.reversedClientID
        )

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        // Checked before the code is read: a callback carrying somebody else's `state` is one we
        // did not start, and redeeming its code would attach their account to this device.
        guard value("state") == state else { throw GoogleSignInError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else {
            throw GoogleSignInError.noAuthorizationCode
        }

        return try await redeem(code: code, verifier: pkce.verifier)
    }

    static func authorizationURL(config: GoogleOAuthConfig, pkce: PKCEChallenge, state: String) -> URL {
        var components = URLComponents(url: GoogleOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleOAuthConfig.scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
        ]
        return components.url!
    }

    private func redeem(code: String, verifier: String) async throws -> GoogleExchange {
        var request = URLRequest(url: GoogleOAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "code", value: code),
            // No `client_secret`. A public client has none, and PKCE is what stands in for it.
            .init(name: "code_verifier", value: verifier),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: config.redirectURI),
        ]
        request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }

        let (data, response) = try await exchange(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleSignInError.transport
        }
        guard let token = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data),
              !token.idToken.isEmpty
        else { throw GoogleSignInError.noIdentityToken }

        return GoogleExchange(identityToken: token.idToken, displayName: nil)
    }
}

/// Only `id_token` is read. `access_token` is deliberately dropped on the floor — we hold no
/// Google scopes worth calling, and keeping a token we never use is a credential to lose.
nonisolated struct GoogleTokenResponse: Decodable {
    let idToken: String

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}
