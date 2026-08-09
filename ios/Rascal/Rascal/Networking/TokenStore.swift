import Foundation
import Security

nonisolated struct TokenPair: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
}

/// Where the session lives between launches.
///
/// Keychain rather than UserDefaults: these tokens reach a child's photos and voice. Backed by
/// `kSecAttrAccessibleAfterFirstUnlock` so a background refresh after a reboot still works,
/// while the values stay unreadable on a device that has never been unlocked.
nonisolated protocol TokenStoring: Sendable {
    func load() -> TokenPair?
    func save(_ pair: TokenPair)
    func clear()
}

nonisolated final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
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
    func save(_ pair: TokenPair) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(
            StoredTokens(access: pair.accessToken, refresh: pair.refreshToken)
        ) else { return }

        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
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

    func save(_ pair: TokenPair) {
        lock.lock(); defer { lock.unlock() }
        self.pair = pair
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pair = nil
    }
}
