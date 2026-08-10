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

        // Both finished is its own reading rather than two "done" clauses, because two clauses
        // is a list and this is a single, quiet fact.
        let everythingDone = [snapshot.mission, snapshot.question]
            .compactMap { $0 }
            .allSatisfy(\.isDone)

        if everythingDone {
            return "\(opening) Both done."
        }

        return ([opening] + parts).joined(separator: " ")
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

    /// One line, for `accessoryInline` — which is a single run of text beside the clock and has
    /// room for a clause, not a sentence.
    static func inline(for state: WidgetSnapshotState) -> String {
        switch state {
        case .absent, .stale:
            return "Today's prompts"
        case .current(let snapshot):
            let mission = snapshot.mission
            let question = snapshot.question
            let pending = [mission, question].compactMap { $0 }.filter { !$0.isDone }

            guard let next = pending.first else {
                return [mission, question].compactMap { $0 }.isEmpty
                    ? "Nothing waiting"
                    : "Today: both done"
            }
            return PromptText.wordSafe(next.body, within: 44)
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
