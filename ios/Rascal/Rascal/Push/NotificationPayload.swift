import Foundation

/// What a tapped notification means, expressed as the link the app already knows how to follow.
///
/// **This deliberately produces a `WidgetDeepLink` rather than a route of its own.** The widget
/// already encodes the rule that matters — an assignment the board does not hold lands on Today,
/// never on a composer for nothing — in `WidgetDeepLink.parse` and
/// `TodayBoard.route(forAssignment:)`. A second router would be a second place for that rule to
/// drift out of, and it is precisely the rule that must not drift.
///
/// The server's payload, from `PushMessage.payload()`:
///
/// ```json
/// { "aps": { "alert": { "title": "…", "body": "…" }, "sound": "default" },
///   "assignment_id": "8f14e45f-ceea-467a-9b0e-4c4d5a5f8b21" }
/// ```
nonisolated enum NotificationPayload {

    /// The key the server writes the assignment under, at the payload's top level rather than
    /// inside `aps` — Apple reserves `aps` and anything custom in there is undefined behaviour.
    static let assignmentKey = "assignment_id"

    /// Read a tapped notification's `userInfo`.
    ///
    /// **Never returns nil.** A payload with no assignment, an unparseable one, or one carrying
    /// an id this device has never heard of is still a parent who deliberately tapped a
    /// notification, and the honest answer to all three is Today. Returning nil would let a
    /// caller do nothing at all, which reads as the app ignoring the tap.
    static func link(from userInfo: [AnyHashable: Any]) -> WidgetDeepLink {
        guard let raw = userInfo[assignmentKey] as? String,
              let id = UUID(uuidString: raw)
        else { return .today }
        return .assignment(id)
    }
}
