import Foundation
import OSLog
import Security

nonisolated struct TokenPair: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
}

/// Where the session lives between launches.
///
/// Keychain rather than UserDefaults: these tokens reach a child's photos and voice. Backed by
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so a background refresh after a reboot
/// still works, while the values stay unreadable on a device that has never been unlocked.
///
/// **`ThisDeviceOnly`, and the suffix is the point.** Without it the pair is *migratable*: it
/// rides along in an encrypted Finder or iCloud backup and restores onto a different handset,
/// where it is a live, rotating session over a child's entire archive that the parent has no
/// way to see. The documented requirement above — a refresh after a reboot, before first
/// unlock — is met identically by both classes, so migratability buys nothing and costs that.
/// The one thing it gives up is a session surviving a restore-to-new-phone, and signing in
/// again is the correct price for that.
nonisolated protocol TokenStoring: Sendable {
    func load() -> TokenPair?
    /// Returns whether the pair actually reached storage.
    ///
    /// **The return value exists because the refresh path cannot afford to guess.** Rotation is
    /// destructive server-side — `rotate_refresh_token` revokes the presented token *before*
    /// issuing the replacement — so a write that silently no-ops leaves this phone holding a token
    /// the server has already killed. The launch it happens on works perfectly, off the pair still
    /// in memory; the next one presents the dead token, takes `refresh_token_reused`, and the
    /// entire chain is revoked. That is a permanent sign-out with a perfect network and no server
    /// fault, and until phase 132 nothing anywhere could tell it had happened.
    @discardableResult
    func save(_ pair: TokenPair) -> Bool
    func clear()
}

nonisolated final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
    private static let log = Logger(subsystem: "app.rascal", category: "keychain")

    private let service: String
    private let account = "session"
    private let lock = NSLock()

    init(service: String = Bundle.main.bundleIdentifier.map { "\($0).tokens" } ?? "rascal.tokens") {
        self.service = service
    }

    func load() -> TokenPair? {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredTokens.self, from: data)
        else { return nil }

        return TokenPair(accessToken: stored.access, refreshToken: stored.refresh)
    }

    /// Both tokens, always together. Persisting only the access token is the specific mistake
    /// that guarantees a forced logout: refresh is rotating, so the old refresh token is dead
    /// the moment a new pair is issued.
    @discardableResult
    func save(_ pair: TokenPair) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(
            StoredTokens(access: pair.accessToken, refresh: pair.refreshToken)
        ) else { return false }

        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Device-bound on purpose — see the note on `TokenStoring`. An item written by an
            // older build with the migratable class is rewritten with this one by the
            // `SecItemUpdate` below, so nothing has to migrate it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // **Every OSStatus here is now read, and that is the whole change.**
        //
        // This used to compare `SecItemUpdate`'s status against one value and throw `SecItemAdd`'s
        // away entirely, so any other failure — `errSecInteractionNotAllowed` from a write before
        // first unlock, `errSecDuplicateItem`, a `-34018` keychain-daemon fault — was
        // indistinguishable from success. See the note on `TokenStoring.save` for why a silent
        // failure here is a permanent sign-out rather than a retry.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            Self.log.error("keychain update refused the token pair: OSStatus \(updated, privacy: .public)")
            return false
        }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added != errSecSuccess {
            Self.log.error("keychain add refused the token pair: OSStatus \(added, privacy: .public)")
        }
        return added == errSecSuccess
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private struct StoredTokens: Codable {
        let access: String
        let refresh: String
    }
}

/// For tests and previews. Never used by the app.
nonisolated final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pair: TokenPair?

    init(_ pair: TokenPair? = nil) { self.pair = pair }

    func load() -> TokenPair? {
        lock.lock(); defer { lock.unlock() }
        return pair
    }

    @discardableResult
    func save(_ pair: TokenPair) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.pair = pair
        return true
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pair = nil
    }
}
