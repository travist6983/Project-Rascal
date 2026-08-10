import Foundation

/// What VoiceOver reads.
///
/// **A widget has to read as a sentence, not as a pile of labels.** Left to itself, SwiftUI makes
/// every `Text` and every symbol its own element, so the small family announces "Mission", then
/// "camera", then the prompt, then "Question", then a checkmark — five stops for a thing a parent
/// can read at one glance. The views below collapse to a single accessibility element and hand it
/// one of these strings.
///
/// It lives in the app target rather than the extension because the tests cannot reach the
/// extension's sources at all, and a sentence nobody asserts on is a sentence that rots.
nonisolated enum WidgetNarration {

    /// The full reading, for every family except `accessoryInline`.
    static func sentence(for state: WidgetSnapshotState) -> String {
        switch state {
        case .absent:
            return "No prompts yet. Open the app to get started."

        case .stale(let name):
            // Deliberately does not say "yesterday" or name a day. The widget knows the snapshot
            // is not today's; it does not know what a parent did or did not do, and guessing is
            // how a neutral state turns into a comment on someone's week.
            return name.isEmpty
                ? "Today's prompts aren't loaded. Open the app to see them."
                : "Today's prompts for \(name) aren't loaded. Open the app to see them."

        case .current(let snapshot):
            return current(snapshot)
        }
    }

    private static func current(_ snapshot: WidgetSnapshot) -> String {
        let opening = snapshot.childFirstName.isEmpty
            ? "Today."
            : "Today for \(snapshot.childFirstName)."

        let parts = [
            phrase(snapshot.mission, called: "Mission"),
            phrase(snapshot.question, called: "Question"),
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return "\(opening) Nothing waiting."
        }

        // Everything finished is its own reading rather than two "done" clauses, because two
        // clauses is a list and this is a single, quiet fact.
        //
        // **"All", not "both".** A day does not always produce two prompts — a dismissed question,
        // or a day the scheduler had nothing active to serve, leaves one — and `isComplete` is
        // true for a single finished prompt just as it is for a pair. Saying "both" there names a
        // second prompt that never existed.
        if snapshot.isComplete {
            return "\(opening) All done."
        }

        return ([opening] + parts).joined(separator: " ")
    }

    /// One prompt, as a sentence of its own.
    ///
    /// **`systemMedium` reads two of these rather than one combined sentence, on purpose.** That
    /// family draws each prompt as its own `Link`, and collapsing the widget into a single
    /// accessibility element — which is right for every other family, because they have one tap
    /// target — would hide both links from VoiceOver. A sighted parent could open the question
    /// directly and a VoiceOver user could only open the app. Two sentences, both actionable, is
    /// the better trade, and two sentences is still not a pile of labels.
    static func line(for featured: WidgetSnapshot.Featured) -> String {
        phrase(featured.item, called: featured.label) ?? featured.label
    }

    /// "Mission: take a photo of…" — or, when it is finished, "Mission, done."
    ///
    /// A finished prompt does not repeat its own words. The parent has already answered it, and
    /// reading the question back to them is the archive talking about itself.
    private static func phrase(_ item: WidgetSnapshot.Item?, called label: String) -> String? {
        guard let item else { return nil }
        if item.isDone { return "\(label), done." }
        return "\(label): \(sentenceEnded(item.body))"
    }

    /// One line, for `accessoryInline`.
    ///
    /// **A status, not a prompt, and the XXL screenshots are why.** The inline slot is a single
    /// system-laid-out run of text beside the clock; nothing can measure it, `ViewThatFits` has no
    /// second dimension to work in, and at accessibility type iOS truncated the prompt to "What
    /// did y…". A half-asked question on a Lock Screen is worse than no question — it is unusable
    /// *and* it puts a fragment of the archive's words in front of whoever is holding the phone.
    ///
    /// So this family says which kind of thing is waiting and stops. The rectangular family is
    /// where the Lock Screen carries the actual words, and it has the room to do it properly.
    static func inline(for state: WidgetSnapshotState) -> String {
        switch state {
        case .absent, .stale:
            return "Today's prompts"
        case .current(let snapshot):
            if snapshot.isEmpty { return "Nothing waiting" }
            guard let next = snapshot.nextUp else { return "All done" }
            return "\(next.label) waiting"
        }
    }

    /// VoiceOver runs clauses together without a full stop, so a prompt that already ends in one
    /// keeps it and a prompt that does not gets one.
    private static func sentenceEnded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
