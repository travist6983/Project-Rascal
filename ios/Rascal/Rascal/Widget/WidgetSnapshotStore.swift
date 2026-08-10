import Foundation

/// Where the snapshot lives, and the only code that touches the shared container.
///
/// **Written by the app, read by the widget, and never the other way round.** The extension has
/// write access in the file-system sense — an App Group is not one-directional — so this is a
/// discipline rather than a permission, and it is worth stating: two writers with no coordination
/// is how a file starts disagreeing with itself.
nonisolated struct WidgetSnapshotStore: Sendable {

    /// Must match both `.entitlements` files exactly. Derived from the bundle id, which is
    /// name-neutral on purpose — the app's name is still open, and this identifier is permanent.
    static let appGroupIdentifier = "group.com.travisterry.childarchive"

    static let filename = "today.json"

    /// Nil when the App Group container is unavailable, which is not an error worth surfacing:
    /// it is what a build with entitlements stripped looks like, and CI builds exactly that with
    /// `CODE_SIGNING_ALLOWED=NO`. Every operation degrades to doing nothing, and the widget
    /// resolves `.absent`.
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    /// The real container. Injectable above, so a test drives a temporary directory rather than
    /// depending on an entitlement the test runner does not have.
    static var shared: WidgetSnapshotStore {
        WidgetSnapshotStore(
            directory: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            )
        )
    }

    var fileURL: URL? {
        directory?.appending(path: Self.filename)
    }

    // MARK: Reading

    /// Raw bytes, or nil. Deliberately does not decode: classification belongs to
    /// `WidgetSnapshotState.resolve`, which has to tell a corrupt file from a missing one.
    func readData() -> Data? {
        guard let fileURL else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    func state(now: Date) -> WidgetSnapshotState {
        WidgetSnapshotState.resolve(data: readData(), now: now)
    }

    // MARK: Writing

    /// Replace the snapshot.
    ///
    /// **Atomic, because the reader is a separate process that is never asked to wait.** A
    /// widget refresh can land in the middle of this write; `.atomic` stages the bytes in a
    /// neighbouring file and renames over the destination, so a reader sees either the whole
    /// previous snapshot or the whole new one. Without it, the widget's failure mode is a
    /// truncated JSON document, which decodes to nothing and blanks the widget at random.
    ///
    /// **`.completeFileProtectionUntilFirstUserAuthentication` is the Lock Screen's requirement,
    /// not a preference.** The default protection class makes a file unreadable while the device
    /// is locked — which is precisely when an `accessoryRectangular` widget is asked to draw. The
    /// widget would render correctly all day and go blank on the Lock Screen after a reboot,
    /// which is both the least testable and the most visible way to get this wrong. The file
    /// holds prompts and a first name and nothing private, so the weaker class costs nothing.
    ///
    /// Failures are swallowed on purpose. A snapshot that cannot be written is a widget showing
    /// the previous one — the app's own work is unaffected, and there is no user-facing recovery
    /// worth interrupting a parent for.
    @discardableResult
    func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let directory, let fileURL else { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            return false
        }
    }

    /// Remove the snapshot. Signing out, in particular: a widget must not keep a signed-out
    /// child's name and prompts on the Lock Screen.
    @discardableResult
    func clear() -> Bool {
        guard let fileURL else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch CocoaError.fileNoSuchFile {
            // Already gone is the outcome this asked for.
            return true
        } catch {
            return false
        }
    }
}
