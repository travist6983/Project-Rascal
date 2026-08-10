import AuthenticationServices
import Foundation

/// Sign in with Apple, reduced to the three values RASCAL actually needs.
///
/// The whole file exists to keep `ASAuthorizationAppleIDCredential` — a type that cannot be
/// constructed in a test — out of the session machine. Everything above this seam takes
/// `AppleCredentialInput`, which is a plain struct.

// MARK: - What comes back from Apple

/// The useful contents of an `ASAuthorizationAppleIDCredential`.
nonisolated struct AppleCredentialInput: Equatable, Sendable {
    /// Apple's stable subject for this (Apple ID, app) pair. Kept so a later launch can ask
    /// `getCredentialState` whether the parent revoked us in Settings.
    let userID: String
    let identityToken: String
    let authorizationCode: String?
    /// **Non-nil only on the very first authorization for a given Apple ID, ever.**
    ///
    /// Deleting and reinstalling the app does not reset it. Already trimmed, and already nil
    /// rather than `""` — see `init?(_:)`, which is where blank is turned into absent so that
    /// nothing downstream has to remember to.
    let fullName: String?
}

extension AppleCredentialInput {
    /// Returns nil when the credential carries no usable identity token, which is the only part
    /// the exchange genuinely cannot proceed without.
    init?(_ credential: ASAuthorizationAppleIDCredential) {
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty
        else { return nil }

        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }

        self.init(
            userID: credential.user,
            identityToken: token,
            authorizationCode: code?.isEmpty == false ? code : nil,
            fullName: Self.name(from: credential.fullName)
        )
    }

    /// `PersonNameComponents` → a display name, or nil.
    ///
    /// Apple can hand back components that are all empty — a parent who declined to share their
    /// name still produces a non-nil `fullName` object. Formatting that yields `""`, and `""`
    /// must never reach the wire: the server cannot tell an empty string from a deliberate blank
    /// name, and it would win first-write-wins and permanently occupy the field.
    static func name(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter
            .string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : formatted
    }
}

// MARK: - What goes to the server

/// The exact bytes of one `POST /v1/auth/apple` attempt, held so a failure can retry the
/// *identical* payload.
///
/// Re-prompting Apple after a failed exchange is the one recovery that cannot work: the second
/// authorization returns `fullName: nil`, so the name is gone for good. This type is what makes
/// the retry a retry rather than a fresh request.
///
/// **In memory only.** A lost name is acceptable; a child's parent's name sitting in UserDefaults
/// or the keychain to survive a process death is not.
nonisolated struct AppleExchange: Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String?
    let displayName: String?

    init(identityToken: String, authorizationCode: String?, displayName: String?) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.displayName = displayName
    }

    init(_ credential: AppleCredentialInput) {
        self.init(
            identityToken: credential.identityToken,
            authorizationCode: credential.authorizationCode,
            displayName: credential.fullName
        )
    }
}

/// The request body. **`display_name` is omitted when absent, never sent as null or `""`.**
///
/// Written out by hand rather than left to the synthesized `Encodable`. Swift's synthesis does
/// use `encodeIfPresent` for optionals today, which happens to be correct — but this is the one
/// field where "happens to be correct" is not good enough. A name Apple supplies exactly once in
/// the lifetime of an install is unrecoverable if this key is wrong, so the behaviour is written
/// down where someone editing it has to see the reason.
nonisolated struct AppleSignInRequest: Encodable {
    let identityToken: String
    let authorizationCode: String?
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case identityToken, authorizationCode, displayName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identityToken, forKey: .identityToken)
        try container.encodeIfPresent(authorizationCode, forKey: .authorizationCode)
        // encodeIfPresent, so a nil name leaves the key out of the object entirely.
        try container.encodeIfPresent(displayName, forKey: .displayName)
    }
}

// MARK: - Credential state

/// What Apple says about a credential we already hold.
nonisolated enum AppleCredentialState: Equatable, Sendable {
    case authorized
    /// The parent revoked us in Settings → Apple ID → Sign in with Apple.
    case revoked
    /// Apple has never heard of this pairing — a restored backup, or a different Apple ID.
    case notFound
    /// Could not be determined. **Treated as authorized**, deliberately: this call needs the
    /// network, and signing someone out of their own archive because a train went into a tunnel
    /// would be the worse failure by a distance.
    case unknown
}

nonisolated protocol AppleCredentialChecking: Sendable {
    func state(forUserID userID: String) async -> AppleCredentialState
}

nonisolated struct LiveAppleCredentialCheck: AppleCredentialChecking {
    func state(forUserID userID: String) async -> AppleCredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: Self.map(state))
            }
        }
    }

    private static func map(_ state: ASAuthorizationAppleIDProvider.CredentialState) -> AppleCredentialState {
        switch state {
        case .authorized: .authorized
        case .revoked: .revoked
        case .notFound: .notFound
        case .transferred: .authorized
        @unknown default: .unknown
        }
    }
}

/// Where the Apple subject id lives between launches.
///
/// UserDefaults rather than the keychain, on the same reasoning as `UserRecordStore`: the token
/// is the secret, and an opaque provider subject is not. It is cleared on sign-out along with
/// everything else about the account.
nonisolated protocol AppleUserIDStoring: AnyObject, Sendable {
    func load() -> String?
    func save(_ userID: String)
    func clear()
}

nonisolated final class UserDefaultsAppleUserIDStore: AppleUserIDStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "session.appleUserID") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> String? { defaults.string(forKey: key) }
    func save(_ userID: String) { defaults.set(userID, forKey: key) }
    func clear() { defaults.removeObject(forKey: key) }
}

nonisolated final class InMemoryAppleUserIDStore: AppleUserIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ userID: String? = nil) { self.stored = userID }

    func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ userID: String) {
        lock.lock(); defer { lock.unlock() }
        stored = userID
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
