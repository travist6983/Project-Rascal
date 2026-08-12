import Foundation

/// Reduces the Today board to the two lines a widget can hold.
///
/// Pure, and separate from the writing, so the selection rules below are testable without an App
/// Group container in the picture.
enum WidgetSnapshotBuilder {

    /// Today's mission and today's question, from the board Today is already rendering.
    ///
    /// **Built from the merged board rather than the server response**, which is what makes a
    /// completion reach the Home Screen the instant Save is tapped: `TodayBoard.merge` folds local
    /// entries over the server's answer, so `isDone` is true before the upload has landed. The
    /// widget then agrees with the screen the parent just left, instead of with the network.
    ///
    /// **`waiting` is deliberately not consulted.** Those are previous days' prompts, and a
    /// widget is not the place to be reminded of them — there is no backlog count anywhere in
    /// this product. `doneToday` *is* consulted, because that is where the board moves an item
    /// the moment it is finished, but every candidate is filtered on `assignedOn == board.date`
    /// first: an item assigned on Tuesday and finished on Wednesday belongs to Tuesday, and
    /// showing it as today's mission is presenting the wrong day.
    static func snapshot(from board: TodayBoard, familyTimezone: String) -> WidgetSnapshot {
        let candidates = (board.today + board.doneToday)
            .filter { $0.assignment.assignedOn == board.date }

        return WidgetSnapshot(
            assignedOn: board.date,
            familyTimezone: familyTimezone,
            childFirstName: firstName(of: board.child.name),
            // **Two daily missions, one widget line.** `mission` first, then `mission_b` — the
            // same order the server's notification ladder uses, so the phone that buzzes and the
            // Home Screen agree about which one is "the" mission today.
            //
            // The fallback is not hypothetical. `mission` draws from the photo pool, which is the
            // thinnest of the three, so the days it comes back empty are the days this matters:
            // without the second lookup the widget would show no mission at all while one was
            // sitting on the Today board.
            mission: item(in: candidates, slot: .mission)
                ?? item(in: candidates, slot: .missionB),
            question: item(in: candidates, slot: .question)
        )
    }

    /// A dismissed or expired assignment is nothing to show rather than something to report. The
    /// parent already said no to one of them, and the app never mentions the other again.
    private static func item(
        in candidates: [TodayBoard.BoardItem],
        slot: Slot
    ) -> WidgetSnapshot.Item? {
        guard let found = candidates.first(where: {
            $0.assignment.slotKind == slot
                && $0.assignment.status != .dismissed
                && $0.assignment.status != .expired
        }) else { return nil }

        // **`body` is the parent's own words when `is_custom` is true**, because the server serves
        // `custom_body` in that field. That is deliberate and it stays: the widget's whole job is
        // to show today's prompt, and silently showing nothing on the days a parent wrote their
        // own would be a stranger failure than showing it. It is still a *prompt* — the question
        // being asked, not the answer — which is the line the privacy rule actually draws, and
        // nothing here can reach an entry. Worth knowing, though, that a custom prompt can be more
        // personal than a library one, and this is the surface where it reaches a Lock Screen.
        return WidgetSnapshot.Item(
            assignmentId: found.assignment.id,
            body: found.assignment.body,
            kind: found.assignment.kind,
            isDone: found.isDone
        )
    }

    /// "Theodore Terry" → "Theodore". A name with no space is already a first name, and an empty
    /// one stays empty rather than becoming a placeholder — the views read better with no name
    /// than with a stand-in for one.
    static func firstName(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }
}
