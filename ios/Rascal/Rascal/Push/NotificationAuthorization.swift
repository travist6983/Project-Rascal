import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// The system's answer about notification permission, reduced to the three cases this app acts
/// on differently.
///
/// `UNAuthorizationStatus` has five. `.provisional` and `.ephemeral` are both deliberately out
/// of scope for this phase — provisional authorization delivers quietly without ever asking,
/// which is precisely the "ask first, and mean it" contract this feature is built on — so they
/// fold into `authorized` if the system ever reports one rather than being silently dropped.
nonisolated enum NotificationAuthorizationStatus: Equatable, Sendable {
    /// The system prompt has never been shown. **The only status from which it can still fire.**
    case notDetermined
    case authorized
    /// The parent refused, in the system prompt or in iOS Settings afterwards. **Terminal.**
    case denied
}

/// The seam over `UNUserNotificationCenter`.
///
/// It exists so that every assertion about permission ordering — and the one that matters most,
/// that "Not now" never reaches the system prompt — can run in a test. A rule that can only be
/// checked by watching a simulator show a dialog is a rule nothing checks.
nonisolated protocol NotificationAuthorizing: Sendable {
    func status() async -> NotificationAuthorizationStatus
    /// Fire the system prompt. Returns what the parent chose.
    ///
    /// iOS shows this **once, ever**, per install. Calling it a second time returns the standing
    /// decision without showing anything, which is why the app must never spend it speculatively.
    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationStatus
    /// Ask the system to mint an APNs token. No-op where UIKit is absent.
    func registerForRemoteNotifications() async
}

/// Picks the real authorizer where the frameworks exist.
///
/// A factory rather than a default argument because `LiveNotificationAuthorization` is
/// conditionally compiled, and a default argument naming it would stop this file compiling
/// anywhere `UserNotifications` is absent.
nonisolated enum NotificationAuthorizerFactory {
    static func live() -> any NotificationAuthorizing {
        #if canImport(UserNotifications) && canImport(UIKit)
        LiveNotificationAuthorization()
        #else
        // Nothing can be asked and nothing can be granted, so the honest answer is a permanent
        // `notDetermined` that never fires a prompt.
        UnavailableNotificationAuthorization()
        #endif
    }
}

/// Used only where the notification frameworks are absent. Never reached on iOS.
nonisolated struct UnavailableNotificationAuthorization: NotificationAuthorizing {
    func status() async -> NotificationAuthorizationStatus { .notDetermined }
    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationStatus { .notDetermined }
    func registerForRemoteNotifications() async {}
}

#if canImport(UserNotifications) && canImport(UIKit)
import UIKit

nonisolated struct LiveNotificationAuthorization: NotificationAuthorizing {
    func status() async -> NotificationAuthorizationStatus {
        Self.reduce(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationStatus {
        // `.alert, .sound` and nothing else. No badge: a count on the icon is a tally of things
        // undone, and this app does not keep one. No `.provisional`, per the type's note above.
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        // A throw here is not "denied" — it is "we could not find out". Re-reading settings is
        // the honest answer, and it keeps a transient failure from being recorded as a refusal
        // the app then never re-offers.
        return granted ? .authorized : await status()
    }

    func registerForRemoteNotifications() async {
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    static func reduce(_ status: UNAuthorizationStatus) -> NotificationAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .notDetermined
        }
    }
}
#endif
