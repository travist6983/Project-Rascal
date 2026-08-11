import Foundation

/// Everything that talks to the server about this phone and this preference.
///
/// One seam rather than two, because every caller that registers also writes a preference, and a
/// test that stubs one and not the other proves less than it looks like it does.
nonisolated protocol PushBackend: Sendable {
    /// Ask the system for a token and post whatever we hold. **Never throws and never blocks
    /// anything.** Registration failure is not a state the parent is told about.
    func register() async
    /// `DELETE /v1/devices/{token}`. Called on sign-out, **before the session is cleared** — the
    /// call needs the bearer token it is revoking against.
    func revoke() async
    func updatePreference(enabled: Bool?, time: NotifyTime?) async throws -> UserResponse
}

// MARK: - The token this phone currently holds

/// Where the APNs token lives between the delegate callback that mints it and the calls that use
/// it.
///
/// Persisted, because sign-out has to revoke a token that may have been minted on a previous
/// launch — APNs only calls back when it feels like it, and a sign-out in the first second of a
/// cold launch would otherwise have nothing to revoke and leave a live token on a signed-out
/// phone. It is a routing address, not a credential, so `UserDefaults` is the right place for it
/// and the keychain would be theatre.
nonisolated protocol PushTokenStoring: AnyObject, Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

nonisolated final class UserDefaultsPushTokenStore: PushTokenStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "push.deviceToken") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> String? { defaults.string(forKey: key) }
    func save(_ token: String) { defaults.set(token, forKey: key) }
    func clear() { defaults.removeObject(forKey: key) }
}

nonisolated final class InMemoryPushTokenStore: PushTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(_ token: String? = nil) { self.token = token }

    func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func save(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}

/// APNs hands the token over as raw bytes. The server wants hex.
nonisolated enum PushTokenFormat {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The live registrar

nonisolated final class PushRegistrar: PushBackend, @unchecked Sendable {
    private let api: APIClient
    private let tokens: any PushTokenStoring
    private let authorizer: any NotificationAuthorizing
    private let environment: PushEnvironment

    init(
        api: APIClient,
        tokens: any PushTokenStoring = UserDefaultsPushTokenStore(),
        authorizer: any NotificationAuthorizing,
        environment: PushEnvironment = .current
    ) {
        self.api = api
        self.tokens = tokens
        self.authorizer = authorizer
        self.environment = environment
    }

    /// Called on every launch that is authorized, and after a grant.
    ///
    /// **Tokens rotate**, so this re-registers unconditionally rather than caching a "already
    /// done" flag; `POST /v1/devices` is idempotent on `(token, environment)` and refreshes
    /// `last_seen_at` rather than growing a second row.
    func register() async {
        await authorizer.registerForRemoteNotifications()
        // The delegate callback may not have arrived yet on this launch. Whatever we already
        // hold is still valid and still worth refreshing; the callback will post again when it
        // lands, and the endpoint is idempotent.
        guard let token = tokens.load() else { return }
        await post(token)
    }

    /// The APNs callback landed. Store it and post it.
    func receive(token data: Data) async {
        let token = PushTokenFormat.hex(data)
        tokens.save(token)
        await post(token)
    }

    private func post(_ token: String) async {
        // **Silent and non-fatal, always.** A device that could not register still launches,
        // still onboards, and still shows nothing about it. The failure costs one day's
        // notification and the next launch tries again.
        _ = try? await api.registerDevice(token: token, environment: environment)
    }

    func revoke() async {
        guard let token = tokens.load() else { return }
        // Failure here is swallowed for the same reason, with one consequence worth naming: a
        // revoke that fails leaves the server willing to send to a signed-out phone until the
        // next sign-in re-registers it. The alternative — blocking sign-out on a network call —
        // is worse, and the server revokes across both environments so one success is enough.
        try? await api.revokeDevice(token: token)
        tokens.clear()
    }

    func updatePreference(enabled: Bool?, time: NotifyTime?) async throws -> UserResponse {
        try await api.updateMe(notifyEnabled: enabled, notifyLocalTime: time)
    }
}
