import Foundation

/// What the widget's timeline should contain, decided as data rather than inside the provider.
///
/// **This exists because a timeline entry's state is frozen when the timeline is built.** The
/// provider reads the snapshot once, and every render until the next refresh draws that same
/// value — so a widget built at 9pm still says "today" at 1am unless something replaces it.
///
/// The first version leaned entirely on `.after(midnight)` to be that something, which is a
/// request rather than a guarantee: WidgetKit is free to delay or drop a refresh, and refresh
/// budget is explicitly out of the app's control. Leaning on it meant the one defect this whole
/// design exists to prevent — yesterday's mission presented as today's — was reachable simply by
/// the system being busy.
///
/// So the rollover is put **in the timeline itself**. A current snapshot emits a second entry,
/// dated the child's midnight and pre-computed as stale. WidgetKit renders a scheduled entry
/// without needing to grant anything, so the day turns over on time even if no refresh is ever
/// granted; the refresh request on top of it is what eventually brings *new* prompts in.
nonisolated struct WidgetTimelinePlan: Equatable, Sendable {

    nonisolated struct Entry: Equatable, Sendable {
        let date: Date
        let state: WidgetSnapshotState
    }

    /// In ascending date order, and never empty.
    let entries: [Entry]
    /// When to ask for a new timeline. A request, not a promise — see above.
    let refresh: Date

    /// Six hours when there is no zone to find a midnight in: a fresh install before the app has
    /// ever run, or a container that is not there. A backstop, not a polling interval — only the
    /// app can change either of those states, and the app pushes its own reload when it does.
    static let fallbackInterval: TimeInterval = 6 * 60 * 60

    static func make(state: WidgetSnapshotState, zone: TimeZone?, now: Date) -> WidgetTimelinePlan {
        let midnight = zone.flatMap { WidgetSnapshot.nextMidnight(after: now, in: $0) }

        var entries = [Entry(date: now, state: state)]

        // Only a current snapshot has anywhere to fall to. Stale and absent are already the
        // neutral state and cannot get worse on their own.
        if case .current(let snapshot) = state, let midnight {
            entries.append(
                Entry(
                    date: midnight,
                    // The same value `resolve` would produce for this snapshot after midnight,
                    // carrying the name and nothing renderable — computed here rather than left
                    // to a refresh that may never come.
                    state: .stale(childFirstName: snapshot.childFirstName)
                )
            )
        }

        return WidgetTimelinePlan(
            entries: entries,
            refresh: midnight ?? now.addingTimeInterval(fallbackInterval)
        )
    }
}
