import Foundation

/// The one place the app delegate can reach.
///
/// APNs delivers two things — the device token, and a tap — to `UIApplicationDelegate` and
/// `UNUserNotificationCenterDelegate` and nowhere else. Neither has a view, a session, or any way
/// to be handed a dependency, so something process-wide has to sit between them and the session
/// that owns the `APIClient`. `MediaCoordinator.shared` exists for the same reason and this is
/// the same shape: **a global by architectural necessity, not by preference.** Do not create a
/// second one.
///
/// It holds no logic of its own. Registration lives in `PushRegistrar`, routing in
/// `NotificationPayload`, and permission in `NotificationPreference`.
@MainActor
@Observable
final class PushCenter {
    static let shared = PushCenter()

    /// Set once, when the session that owns the `APIClient` is built.
    private var registrar: PushRegistrar?

    /// **A token that arrived before there was anything to post it with.**
    ///
    /// APNs answers `registerForRemoteNotifications` on its own schedule, and on a cold launch
    /// that answer can land before the session exists. Dropping it would leave the phone
    /// unregistered until the next foreground — which is a notification the parent never gets,
    /// on the day they turned the feature on.
    private var pendingToken: Data?

    /// A tapped notification, held until something can act on it. Read by `OnboardingGate`,
    /// which is the only view that is always on screen — the same reason it, and not `RootView`,
    /// catches widget URLs.
    var pendingLink: WidgetDeepLink?

    private init() {}

    func attach(_ registrar: PushRegistrar) {
        self.registrar = registrar
        guard let token = pendingToken else { return }
        pendingToken = nil
        Task { await registrar.receive(token: token) }
    }

    /// `didRegisterForRemoteNotificationsWithDeviceToken`.
    func receive(token: Data) {
        guard let registrar else {
            pendingToken = token
            return
        }
        Task { await registrar.receive(token: token) }
    }

    /// `didReceive response` — the parent tapped it.
    func handleTap(userInfo: [AnyHashable: Any]) {
        pendingLink = NotificationPayload.link(from: userInfo)
    }
}
