import Foundation

/// Where the pull's position between launches lives, and the switch that gates it.
///
/// Same shape as `TokenStoring`: a protocol, a real implementation, and a seam a test can drive
/// without touching the device. **Not** the keychain, which holds the session — a cursor is a
/// timestamp, not a secret, and putting it behind `kSecAttrAccessibleAfterFirstUnlock` would give
/// it a failure mode it does not need. **Not** SwiftData either: the store is the thing the pull
/// writes into, and keeping the position outside it means a store that has to be quarantined and
/// rebuilt cannot take a stale cursor with it.
// `AnyObject` so the flag is settable through a `let` reference. Both implementations are
// classes and a value-type one would be wrong anyway: a store is a shared thing.
nonisolated protocol SyncStateStoring: AnyObject, Sendable {
    func cursor(for childId: UUID) -> Date?
    func setCursor(_ cursor: Date?, for childId: UUID)

    /// The last pull that applied cleanly, for the Settings row.
    func lastSuccess(for childId: UUID) -> Date?
    func recordSuccess(_ at: Date, for childId: UUID)

    /// The last failure, so Settings can say what went wrong without a banner anywhere else.
    func lastError(for childId: UUID) -> String?
    func recordError(_ message: String?, for childId: UUID)

    /// **Defaults to false and ships false.** Every write the pull performs is gated on this.
    var pullEnabled: Bool { get set }

    /// Forget every child's position, for a sign-out.
    ///
    /// **The store is emptied and the cursor is not**, which is the bug this closes: signing out
    /// deletes every row and signing back in as the same account then resumes from a timestamp
    /// describing an archive that no longer exists, so `/sync` returns the handful of rows changed
    /// since — and the store silently never refills. Latent only because `pullEnabled` ships false.
    ///
    /// `pullEnabled` is deliberately **not** cleared. It is a device feature flag somebody turned
    /// on, not account data, and it survives a sign-out the way any other setting does.
    func forgetAllChildren()
}

/// UserDefaults-backed, keyed per child.
///
/// Per child rather than global because the cursor is a position in *that child's* change stream;
/// two children share nothing, and one global cursor would make the second child's first pull
/// silently skip everything written before the first child last synced.
nonisolated final class UserDefaultsSyncStateStore: SyncStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let namespace: String

    init(defaults: UserDefaults = .standard, namespace: String = "sync") {
        self.defaults = defaults
        self.namespace = namespace
    }

    // MARK: Cursor

    /// The stored position, or nil when there is not a usable one.
    ///
    /// **A value that cannot be parsed is treated as absent**, which means a full pull from zero.
    /// That is the deliberate choice: re-reading the whole archive costs one large request and
    /// converges, whereas honouring a half-written or foreign timestamp would skip every record
    /// before it, permanently and silently. The same branch is the manual recovery path behind
    /// "Reset cursor" in Settings.
    func cursor(for childId: UUID) -> Date? {
        guard let raw = defaults.string(forKey: cursorKey(childId)) else { return nil }
        return ISO8601Formatters.parse(raw)
    }

    func setCursor(_ cursor: Date?, for childId: UUID) {
        guard let cursor else {
            defaults.removeObject(forKey: cursorKey(childId))
            return
        }
        defaults.set(ISO8601Formatters.string(from: cursor), forKey: cursorKey(childId))
    }

    // MARK: Status

    func lastSuccess(for childId: UUID) -> Date? {
        guard let raw = defaults.string(forKey: successKey(childId)) else { return nil }
        return ISO8601Formatters.parse(raw)
    }

    func recordSuccess(_ at: Date, for childId: UUID) {
        defaults.set(ISO8601Formatters.string(from: at), forKey: successKey(childId))
        defaults.removeObject(forKey: errorKey(childId))
    }

    func lastError(for childId: UUID) -> String? {
        defaults.string(forKey: errorKey(childId))
    }

    func recordError(_ message: String?, for childId: UUID) {
        guard let message else {
            defaults.removeObject(forKey: errorKey(childId))
            return
        }
        defaults.set(message, forKey: errorKey(childId))
    }

    // MARK: The switch

    func forgetAllChildren() {
        // Every key this store owns except the flag, found by prefix rather than by asking for a
        // list of children — the eraser does not have one, and a sign-out has to work for a child
        // this build never loaded.
        let keep = "\(namespace).pullEnabled"
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("\(namespace).") && key != keep {
            defaults.removeObject(forKey: key)
        }
    }

    var pullEnabled: Bool {
        get { defaults.bool(forKey: "\(namespace).pullEnabled") }
        set { defaults.set(newValue, forKey: "\(namespace).pullEnabled") }
    }

    // MARK: Keys

    private func cursorKey(_ childId: UUID) -> String {
        "\(namespace).cursor.\(childId.uuidString)"
    }

    private func successKey(_ childId: UUID) -> String {
        "\(namespace).lastSuccess.\(childId.uuidString)"
    }

    private func errorKey(_ childId: UUID) -> String {
        "\(namespace).lastError.\(childId.uuidString)"
    }
}

/// A store that forgets everything when it goes out of scope. For tests, and for nothing else.
nonisolated final class InMemorySyncStateStore: SyncStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [UUID: Date] = [:]
    private var successes: [UUID: Date] = [:]
    private var errors: [UUID: String] = [:]
    private var enabled: Bool

    func forgetAllChildren() {
        lock.lock(); defer { lock.unlock() }
        cursors.removeAll()
        successes.removeAll()
        errors.removeAll()
        // `enabled` survives, matching the real store: a device flag is not account data.
    }

    init(pullEnabled: Bool = false) {
        self.enabled = pullEnabled
    }

    func cursor(for childId: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return cursors[childId]
    }

    func setCursor(_ cursor: Date?, for childId: UUID) {
        lock.lock(); defer { lock.unlock() }
        cursors[childId] = cursor
    }

    func lastSuccess(for childId: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return successes[childId]
    }

    func recordSuccess(_ at: Date, for childId: UUID) {
        lock.lock(); defer { lock.unlock() }
        successes[childId] = at
        errors[childId] = nil
    }

    func lastError(for childId: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return errors[childId]
    }

    func recordError(_ message: String?, for childId: UUID) {
        lock.lock(); defer { lock.unlock() }
        errors[childId] = message
    }

    var pullEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock(); defer { lock.unlock() }
            enabled = newValue
        }
    }
}
