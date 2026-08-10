import Foundation

/// The URLs the widget opens the app with.
///
/// Shared by both targets on purpose: the widget builds these and the app parses them, and a
/// scheme written twice is a scheme that drifts once. There was no deep-link handling in the app
/// before this — no URL scheme, no `onOpenURL`, nothing — so this is the whole of it.
nonisolated enum WidgetDeepLink: Equatable, Sendable {

    /// Open the composer for one assignment. The app resolves the id against the board it holds.
    case assignment(UUID)

    /// Land on Today. Both a destination in its own right and the fallback for anything that
    /// cannot be understood.
    case today

    /// Registered in `Info.plist` and `Info-Debug.plist`. Named from the bundle id rather than
    /// the product, because the product's name is still open — see `docs/decisions.md`, open
    /// item 1. A URL scheme a parent has tapped is as permanent as a bundle id.
    static let scheme = "childarchive"

    private static let assignmentHost = "assignment"
    private static let todayHost = "today"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .today:
            components.host = Self.todayHost
        case .assignment(let id):
            components.host = Self.assignmentHost
            components.path = "/\(id.uuidString.lowercased())"
        }
        // The components above are fixed strings and a UUID, so this cannot fail. Falling back to
        // the bare scheme rather than force-unwrapping keeps a crash off the Home Screen.
        return components.url ?? URL(string: "\(Self.scheme)://\(Self.todayHost)")!
    }

    /// Parse a URL the system handed the app.
    ///
    /// **Anything wearing our scheme that cannot be read resolves to `.today`, never to nil.** A
    /// widget tapped is a parent expecting the app to open somewhere real; the one outcome that
    /// must be impossible is a composer opened for an assignment that does not exist. Foreign
    /// schemes return nil so the app leaves them to whatever else handles them.
    static func parse(_ url: URL) -> WidgetDeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard url.host()?.lowercased() == assignmentHost else { return .today }

        let identifier = url.pathComponents.first { $0 != "/" } ?? ""
        guard let id = UUID(uuidString: identifier) else { return .today }
        return .assignment(id)
    }
}
