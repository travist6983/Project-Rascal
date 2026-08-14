import Foundation

/// Which child the parent was last looking at.
///
/// **`UserDefaults`, not the keychain and not SwiftData**, for the two reasons `SyncCursorStore`
/// already gives about the sync cursor: a child id is not a secret, so putting it behind
/// `kSecAttrAccessibleAfterFirstUnlock` would buy it a failure mode it does not need — and the
/// SwiftData store is the thing this value is used to *choose between*, so it cannot live inside
/// it. It is a preference about the app, not a row in the archive.
///
/// **Losing it is harmless by construction.** Nothing downstream trusts it: the gate resolves
/// `GET /children` first and only then asks whether the remembered id is among them. An id that
/// is missing, unparseable, or names a child this account no longer has all land on the same
/// branch as never having chosen — the first child. That is why this stores a `String` and
/// parses on the way out rather than refusing to save something malformed: the reader already
/// has to handle "no usable answer", so there is only one path to get right.
nonisolated protocol SelectedChildStoring: AnyObject, Sendable {
    func load() -> UUID?
    func save(_ childId: UUID)
    func clear()
}

nonisolated final class UserDefaultsSelectedChildStore: SelectedChildStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "session.selectedChildID") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> UUID? { defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) }
    func save(_ childId: UUID) { defaults.set(childId.uuidString, forKey: key) }
    func clear() { defaults.removeObject(forKey: key) }
}

nonisolated final class InMemorySelectedChildStore: SelectedChildStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UUID?

    init(_ childId: UUID? = nil) { self.stored = childId }

    func load() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ childId: UUID) {
        lock.lock(); defer { lock.unlock() }
        stored = childId
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
