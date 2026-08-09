import Foundation

/// Where the signed-in user's record lives between launches.
///
/// Same shape as `TokenStoring` and `SyncStateStoring`: a protocol, a real implementation, and a
/// seam a test can drive. **Not** the keychain — the token is the secret, and a display name is
/// not. Not SwiftData either: this is one record about the session rather than a row in the
/// archive, and a store that has to be quarantined and rebuilt should not take the account's own
/// name with it.
///
/// It exists alongside `GET /me` rather than instead of it. The stored copy is what Settings can
/// show *immediately* on a cold launch and offline; the fetch is what makes it right.
nonisolated protocol UserRecordStoring: AnyObject, Sendable {
    func load() -> UserResponse?
    func save(_ user: UserResponse)
    func clear()
}

nonisolated final class UserDefaultsUserRecordStore: UserRecordStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "session.user") {
        self.defaults = defaults
        self.key = key
    }

    /// A record that cannot be decoded is treated as absent.
    ///
    /// The same choice the sync cursor makes, for the same reason: the recovery is one request,
    /// and honouring a half-written record would put a stale or nonsensical name on the account
    /// screen with no way for anyone to work out why.
    func load() -> UserResponse? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? APIClient.decoder.decode(UserResponse.self, from: data)
    }

    func save(_ user: UserResponse) {
        guard let data = try? APIClient.encoder.encode(user) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Forgets everything when it goes out of scope. For tests, and for nothing else.
nonisolated final class InMemoryUserRecordStore: UserRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UserResponse?

    init(_ user: UserResponse? = nil) { self.stored = user }

    func load() -> UserResponse? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ user: UserResponse) {
        lock.lock(); defer { lock.unlock() }
        stored = user
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
