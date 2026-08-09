import SwiftData
import SwiftUI

#if canImport(UIKit)
import UIKit

/// Exists for one method. `handleEventsForBackgroundURLSession` is delivered to the app
/// delegate and nowhere else, and the handler it carries must be called once the session's
/// queue drains — the system waits on it before letting the app suspend again. Skipping it is
/// how background uploads appear to stall for minutes at a time.
final class AppDelegate: NSObject, UIApplicationDelegate {
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
            RootView()
        }
        .modelContainer(container)
    }
}
