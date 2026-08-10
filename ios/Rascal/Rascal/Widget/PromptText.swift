import Foundation

/// Shortening a prompt so it still reads as a sentence.
///
/// **Why this exists rather than `.lineLimit` and a tail truncation.** SwiftUI truncates at the
/// character, so a `systemSmall` widget renders "Go back through your camera roll to this month
/// last year and log three phot…". The seeded library runs to 100 characters — the longest active
/// prompt is a question, and every one of them is a full sentence — so on the smallest family
/// this is the normal case, not an edge one. A word cut in half is the difference between a
/// prompt a parent can read at a glance and a prompt they have to open the app to finish.
///
/// Pure and character-counted, which is an approximation of a width nobody can measure without a
/// layout pass. It is not asked to be exact: the views hand several of these to `ViewThatFits`,
/// which picks the longest one that actually fits at the reader's type size. This function's only
/// job is that every candidate ends on a whole word.
nonisolated enum PromptText {

    /// At most `characters` long, ending on a whole word, with an ellipsis when anything was
    /// dropped. Returns the text unchanged when it already fits.
    ///
    /// A single word longer than the whole budget is returned whole and over-length rather than
    /// split. Nothing in the mission library is close to that, and a broken word is the one
    /// outcome this is here to prevent — overflowing is the better failure, and `ViewThatFits`
    /// will reject the candidate anyway.
    static func wordSafe(_ text: String, within characters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard characters > 0, trimmed.count > characters else { return trimmed }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first else { return trimmed }

        // One character of the budget belongs to the ellipsis.
        let budget = characters - 1
        var kept = String(first)

        for word in words.dropFirst() {
            let candidate = kept + " " + word
            if candidate.count > budget { break }
            kept = candidate
        }

        return tidied(kept) + "…"
    }

    /// Drop the punctuation a sentence was leaning on before it was cut short. "…know you were,"
    /// becomes "…know you were…" rather than "…know you were,…", which reads as a typo.
    private static func tidied(_ text: String) -> String {
        var result = text
        while let last = result.last, last == " " || last == "," || last == ";" || last == ":"
            || last == "—" || last == "-" {
            result.removeLast()
        }
        return result
    }
}
