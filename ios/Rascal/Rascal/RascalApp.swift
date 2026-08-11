import SwiftData
import SwiftUI

#if canImport(UIKit)
import UIKit
import UserNotifications

/// Exists for the methods UIKit delivers nowhere else.
///
/// `handleEventsForBackgroundURLSession` is one. The APNs token callbacks and the notification
/// tap are the others: `UNUserNotificationCenter` hands them to a delegate object, not to a view,
/// so they arrive here and are forwarded straight to `PushCenter`. **No logic lives in this
/// class** — it is a doorway.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before the first frame. A tap that launched the app cold is delivered as soon as
        // the delegate is assigned, and a delegate assigned later misses it entirely.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: APNs

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated { PushCenter.shared.receive(token: deviceToken) }
    }

    /// **Silent and non-fatal.** A phone that could not get a token still launches, still
    /// onboards, and is told nothing about it. There is no recovery a parent could perform.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {}

    // MARK: Presentation and taps

    /// **Suppressed in the foreground.** The one notification this app sends carries today's
    /// mission, and Today is the screen it would banner over — telling a parent who is looking
    /// at the prompt about the prompt. Nothing is lost: it is still in Notification Centre, and
    /// the content is already on screen behind it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run { PushCenter.shared.handleTap(userInfo: userInfo) }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == MediaUploader.sessionIdentifier else {
            completionHandler()
            return
        }
        // Touching `shared` here is what re-creates the session and reattaches the delegate
        // on a launch that exists only to deliver these events.
        // UIKit hands this over non-Sendable, but it is only ever called once, on the main
        // queue, by the delegate. Wrapping states that rather than leaving the compiler to
        // assume the worst.
        let handler = completionHandler
        MediaUploader.shared.backgroundCompletionHandler = { handler() }
        MediaUploader.shared.activate()
    }
}
#endif

@main
struct RascalApp: App {
    /// The local cache. Entries live here first so a save survives a force quit and an offline
    /// launch; the server stays the source of truth for everything it owns.
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    private let container = LocalStore.shared

    var body: some Scene {
        WindowGroup {
            // The gate decides whether this launch has a session and a child, and renders
            // `RootView` once it does. It owns the one `AppSession` in the process.
            OnboardingGate()
        }
        .modelContainer(container)
    }
}
