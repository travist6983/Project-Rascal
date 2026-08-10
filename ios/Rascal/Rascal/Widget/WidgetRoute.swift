import Foundation

/// Where a tap on the widget lands.
///
/// Separated from the view so it can be asserted on. The rule this encodes is the one that
/// matters — **an assignment the board does not hold must land on Today, never on a composer for
/// nothing** — and a rule that only exists inside a SwiftUI view body is a rule nothing can test.
nonisolated enum WidgetRoute: Equatable {
    /// Open the composer for an assignment that is still waiting.
    case composer(AssignmentResponse)
    /// Open the entry a finished assignment already produced. Cheaper than a second composer for
    /// the same prompt, and it is what a parent tapping a done row is looking for.
    case entry(UUID)
    /// Land on Today. The destination for an unknown id, a stale id, and a finished assignment
    /// whose entry this device does not hold a copy of.
    case today
}

/// Deliberately **not** `nonisolated`, unlike everything else in this folder. `TodayBoard` and its
/// items are main-actor isolated like the rest of the app's view layer, and the only caller is
/// `TodayScreen`. The shared files are nonisolated because the extension compiles them; this one
/// is app-only and has no reason to be.
extension TodayBoard {

    /// Resolve a widget's assignment id against the board actually on screen.
    ///
    /// Searches everything the board holds, including `waiting`: a snapshot can outlive the day
    /// it was written for, so an id arriving here may well belong to a prompt that has since
    /// rolled over into the backlog. Opening it is still the right answer — the parent tapped it
    /// deliberately — and it is the *unknown* id, not the old one, that has to be turned away.
    func route(forAssignment id: UUID) -> WidgetRoute {
        let everything = today + waiting + doneToday
        guard let item = everything.first(where: { $0.assignment.id == id }) else { return .today }

        guard item.isDone else { return .composer(item.assignment) }

        // Finished, and this device holds the entry: open it. Finished with no local entry means
        // the completion happened on another phone and has not been pulled down here yet, so
        // there is nothing to open and Today is the honest landing.
        return item.localEntryId.map(WidgetRoute.entry) ?? .today
    }
}
