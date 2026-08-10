import Foundation
import Testing

@testable import Rascal

/// Shortening a prompt, and what VoiceOver reads.
@MainActor
@Suite("Widget text")
struct WidgetTextTests {

    /// **The longest active prompt in `api/seeds/prompts.yaml`**, at 100 characters. Tested
    /// against this rather than a short example, because on `systemSmall` the long ones are the
    /// normal case and the short ones prove nothing.
    private let longest =
        "What did you get wrong as a parent this week? Write it honestly — he'll need to know you were human."

    /// The longest mission, as opposed to the longest question.
    private let longestActivity =
        "Take him on a solo date and let him pick everything — where you go, what you eat, what you do."

    // MARK: Truncation

    @Test("a prompt that already fits is left completely alone")
    func shortTextUntouched() {
        #expect(PromptText.wordSafe("Take a photo.", within: 40) == "Take a photo.")
        // No ellipsis is added to something that was not shortened.
        #expect(!PromptText.wordSafe("Take a photo.", within: 40).hasSuffix("…"))
    }

    /// The assertion the type exists for. SwiftUI's own truncation gives
    /// "…and log three phot…"; this must never cut inside a word.
    @Test("the longest prompt in the library never breaks a word")
    func longestPromptIsNeverCutMidWord() {
        for budget in [14, 20, 24, 30, 36, 44, 52, 60, 72, 88, 99] {
            let result = PromptText.wordSafe(longest, within: budget)
            expectWordSafe(result, of: longest, budget: budget)
        }
    }

    @Test("the longest mission never breaks a word either")
    func longestActivityIsNeverCutMidWord() {
        for budget in [14, 24, 36, 52, 72, 90] {
            expectWordSafe(
                PromptText.wordSafe(longestActivity, within: budget),
                of: longestActivity,
                budget: budget
            )
        }
    }

    @Test("the result stays inside its budget")
    func budgetIsRespected() {
        for budget in [20, 30, 44, 60] {
            #expect(PromptText.wordSafe(longest, within: budget).count <= budget)
        }
    }

    @Test("punctuation the sentence was leaning on is dropped before the ellipsis")
    func trailingPunctuationIsTidied() {
        // "What did you get wrong as a parent this week?" — cutting after "week?" keeps the
        // question mark, which is part of the word. Cutting after a comma drops it.
        let cut = PromptText.wordSafe("One thing, then another thing entirely", within: 12)
        #expect(!cut.contains(",…"))
        #expect(cut.hasSuffix("…"))
    }

    /// A single word longer than the whole budget is returned whole rather than split. Nothing in
    /// the library is close to this, and overflowing is the better failure — `ViewThatFits`
    /// rejects the candidate, where a broken word would have been drawn.
    @Test("one very long word is returned whole rather than broken")
    func oneLongWordIsNotSplit() {
        let word = "Pneumonoultramicroscopicsilicovolcanoconiosis"
        let result = PromptText.wordSafe(word, within: 10)
        #expect(result == word + "…")
    }

    @Test("an empty prompt and a zero budget do not trap")
    func degenerateInputs() {
        #expect(PromptText.wordSafe("", within: 20) == "")
        #expect(PromptText.wordSafe("Take a photo.", within: 0) == "Take a photo.")
        #expect(PromptText.wordSafe("   Take a photo.  ", within: 40) == "Take a photo.")
    }

    /// Every candidate must be a whole-word prefix of the original, and short enough to matter.
    private func expectWordSafe(_ result: String, of original: String, budget: Int) {
        #expect(result.hasSuffix("…"), "budget \(budget): nothing was shortened")

        let kept = String(result.dropLast())
        let originalWords = original.split(separator: " ").map(String.init)
        let keptWords = kept.split(separator: " ").map(String.init)

        #expect(!keptWords.isEmpty, "budget \(budget): everything was dropped")

        for (index, word) in keptWords.enumerated() {
            guard index < originalWords.count else {
                Issue.record("budget \(budget): produced more words than the prompt has")
                return
            }
            // The last kept word may have lost trailing punctuation to `tidied`; every other word
            // has to match exactly, which is what "never cut mid-word" means.
            if index == keptWords.count - 1 {
                #expect(
                    originalWords[index].hasPrefix(word),
                    "budget \(budget): '\(word)' is not a whole word of the prompt"
                )
                #expect(
                    originalWords[index].count - word.count <= 1,
                    "budget \(budget): '\(word)' is '\(originalWords[index])' cut short"
                )
            } else {
                #expect(originalWords[index] == word, "budget \(budget): word \(index) was altered")
            }
        }
    }

    // MARK: VoiceOver

    private func item(_ body: String, kind: String = "photo", done: Bool = false) -> WidgetSnapshot.Item {
        WidgetSnapshot.Item(assignmentId: UUID(), body: body, kind: kind, isDone: done)
    }

    private func snapshot(
        name: String = "Sam",
        mission: WidgetSnapshot.Item?,
        question: WidgetSnapshot.Item?
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            assignedOn: "2026-08-10", familyTimezone: "UTC",
            childFirstName: name, mission: mission, question: question
        )
    }

    /// **A widget has to read as a sentence, not as a pile of labels.** Left to itself SwiftUI
    /// announces "Mission", "camera", the prompt, "Question", a checkmark — five stops for
    /// something read at a glance.
    @Test("both pending reads as one sentence naming both prompts")
    func bothPendingReadsAsASentence() {
        let sentence = WidgetNarration.sentence(for: .current(snapshot(
            mission: item("Photograph his hands."),
            question: item("What made him laugh?", kind: "question")
        )))

        #expect(sentence == "Today for Sam. Mission: Photograph his hands. Question: What made him laugh?")
    }

    @Test("a finished prompt is not read back at the parent")
    func doneIsNotRepeated() {
        let sentence = WidgetNarration.sentence(for: .current(snapshot(
            mission: item("Photograph his hands.", done: true),
            question: item("What made him laugh?", kind: "question")
        )))

        #expect(sentence.contains("Mission, done."))
        #expect(!sentence.contains("Photograph his hands"))
    }

    @Test("everything finished is a single quiet fact, not a list")
    func everythingDoneIsOneClause() {
        let sentence = WidgetNarration.sentence(for: .current(snapshot(
            mission: item("Photograph his hands.", done: true),
            question: item("What made him laugh?", kind: "question", done: true)
        )))

        #expect(sentence == "Today for Sam. All done.")
    }

    /// **"All", not "both".** A day does not always produce two prompts — a dismissed question, or
    /// a day the scheduler had nothing active to serve, leaves one — and a finished single prompt
    /// is just as complete as a finished pair. The reading said "Both done" there, naming a second
    /// prompt that never existed.
    @Test("a day with one prompt, finished, does not claim there were two")
    func singlePromptDoneDoesNotSayBoth() {
        let sentence = WidgetNarration.sentence(for: .current(snapshot(
            mission: item("Photograph his hands.", done: true),
            question: nil
        )))

        #expect(sentence == "Today for Sam. All done.")
        #expect(!sentence.lowercased().contains("both"))

        let inline = WidgetNarration.inline(for: .current(snapshot(
            mission: item("Photograph his hands.", done: true),
            question: nil
        )))
        #expect(inline == "All done")
        #expect(!inline.lowercased().contains("both"))
    }

    @Test("a prompt with no full stop of its own gets one, so clauses do not run together")
    func clausesAreSeparated() {
        let sentence = WidgetNarration.sentence(for: .current(snapshot(
            mission: item("Photograph his hands"),
            question: nil
        )))
        #expect(sentence == "Today for Sam. Mission: Photograph his hands.")
    }

    /// The stale reading names no day and blames nobody. The widget knows the snapshot is not
    /// today's; it does not know what the parent did or did not do.
    @Test("the stale reading is neutral and mentions no prompt")
    func staleReadsNeutrally() {
        let sentence = WidgetNarration.sentence(for: .stale(childFirstName: "Sam"))
        #expect(sentence == "Today's prompts for Sam aren't loaded. Open the app to see them.")
        #expect(!sentence.lowercased().contains("yesterday"))
        #expect(!sentence.lowercased().contains("missed"))
    }

    @Test("the absent reading does not imply anything is wrong")
    func absentReadsNeutrally() {
        let sentence = WidgetNarration.sentence(for: .absent)
        #expect(sentence == "No prompts yet. Open the app to get started.")
        #expect(!sentence.lowercased().contains("error"))
    }

    @Test("a day with no prompts says so plainly")
    func emptyDayReads() {
        let sentence = WidgetNarration.sentence(for: .current(snapshot(mission: nil, question: nil)))
        #expect(sentence == "Today for Sam. Nothing waiting.")
    }

    @Test("a child with no name still reads as a sentence")
    func namelessStillReads() {
        let sentence = WidgetNarration.sentence(for: .current(snapshot(
            name: "", mission: item("Photograph his hands."), question: nil
        )))
        #expect(sentence == "Today. Mission: Photograph his hands.")
    }

    // MARK: The inline family

    /// **The inline family says what is waiting, never what it asks.**
    ///
    /// It began as the prompt itself, shortened. The XXL screenshots showed iOS truncating that
    /// to "What did y…" — the inline slot is a single system-laid-out run beside the clock, so
    /// nothing can measure it and no fallback can fire. A half-asked question is unusable *and*
    /// puts a fragment of the archive in front of whoever is holding the phone. The rectangular
    /// family is where the Lock Screen carries the words.
    @Test("the inline reading is a status, and never a piece of a prompt")
    func inlineIsAStatus() {
        let pending = WidgetNarration.inline(for: .current(snapshot(
            mission: item(longest), question: nil
        )))
        #expect(pending == "Mission waiting")

        let missionDone = WidgetNarration.inline(for: .current(snapshot(
            mission: item("Photograph his hands.", done: true),
            question: item(longest, kind: "question")
        )))
        #expect(missionDone == "Question waiting")

        // Nothing that could be mistaken for the prompt's own words.
        for reading in [pending, missionDone] {
            #expect(!longest.hasPrefix(String(reading.prefix(6))))
            #expect(!reading.hasSuffix("…"))
        }
    }

    @Test("the inline reading is short enough that the system does not cut it")
    func inlineIsShort() {
        let readings = [
            WidgetNarration.inline(for: .absent),
            WidgetNarration.inline(for: .stale(childFirstName: "Sam")),
            WidgetNarration.inline(for: .current(snapshot(mission: nil, question: nil))),
            WidgetNarration.inline(for: .current(snapshot(
                mission: item("A", done: true), question: item("B", kind: "question", done: true)
            ))),
            WidgetNarration.inline(for: .current(snapshot(mission: item(longest), question: nil))),
        ]
        for reading in readings {
            #expect(reading.count <= 16, "'\(reading)' is long enough for iOS to truncate")
        }
    }

    @Test("the inline reading never counts anything")
    func inlineCountsNothing() {
        let readings = [
            WidgetNarration.inline(for: .absent),
            WidgetNarration.inline(for: .stale(childFirstName: "Sam")),
            WidgetNarration.inline(for: .current(snapshot(
                mission: item("A", done: true), question: item("B", kind: "question", done: true)
            ))),
        ]
        for reading in readings {
            let hasDigit = reading.rangeOfCharacter(from: .decimalDigits) != nil
            #expect(!hasDigit, "\(reading) puts a number on a Lock Screen")
        }
    }
}
