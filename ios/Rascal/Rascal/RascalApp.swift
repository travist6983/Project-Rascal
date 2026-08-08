import SwiftData
import SwiftUI

@main
struct RascalApp: App {
    /// The local cache. Entries live here first so a save survives a force quit and an offline
    /// launch; the server stays the source of truth for everything it owns.
    private let container = LocalStore.container()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
