import Foundation

/// Checks a personalized string against the canonical one it came from, and throws it away if it
/// has become a different instruction.
///
/// **The model's output is not trusted, it is validated.** A small model asked to rewrite an
/// instruction will occasionally write a better one, and a better instruction is a different
/// mission. The library is the soul of the product; this is the line that keeps a model on the
/// presentation side of it.
///
/// Every rejection resolves to the canonical text rendering. **None of them is an error state** —
/// nothing is surfaced, nothing is retried, and a parent cannot tell the difference between a
/// rejected personalization and a device that has no model at all. That is by design: the failure
/// mode of this whole feature is "the app works exactly as it did before".
nonisolated enum PersonalizationGuard {

    /// Why a string was thrown away. Counted in debug builds so the rejection rate is observable —
    /// **a high rate is information, not a bug to suppress.**
    nonisolated enum Rejection: String, Equatable, Sendable, CaseIterable {
        /// Materially longer than its source, which means content was added rather than swapped.
        case tooLong
        /// A sentence appeared or vanished. An added sentence is an added instruction.
        case sentenceCountChanged
        /// A question became an instruction or the reverse. Different ask, different entry.
        case questionParityChanged
        /// Tone words the library does not use, from a model that decided to be warm.
        case bannedWord
        /// Substitution was the point and the name never appeared, so canonical is equivalent and
        /// costs nothing.
        case nameAbsent
        /// An instruction verb the canonical text did not contain. A new verb is a new task.
        case newImperativeVerb
    }

    /// Words the library never uses, and the ones a model reaches for when it decides an archive
    /// about a child should sound tender. `docs/mission-library.md`'s tone rules bind anything
    /// rendered as a prompt, including text this app generated.
    static let bannedWords = ["precious", "cherish", "cherished", "treasure", "little moments"]

    /// **Read out of `api/seeds/prompts.yaml`, not invented.** These are the opening verbs of the
    /// 83 instruction-shaped prompts in the shipped library, which is the whole vocabulary of
    /// things this product asks a parent to do.
    ///
    /// The rule is one-directional on purpose: a personalized string may *drop* a verb (it cannot,
    /// in practice, but nothing here forbids it), and may never *introduce* one the canonical text
    /// did not have. "Take a photo of Sam's hands" is the job; "Take a photo of Sam's hands while
    /// he plays" adds no verb but "…and write down what he says" does, and that is a second
    /// mission hiding inside the first.
    static let instructionVerbs: Set<String> = [
        "record", "take", "photograph", "write", "film", "ask", "let", "go", "get",
        "use", "trace", "tell", "spend", "show", "say", "put", "measure", "draw",
        "describe", "count", "list", "read", "sing", "make", "keep", "note",
    ]

    /// How much longer a personalized string may be than its source, before the name is accounted
    /// for.
    ///
    /// A name substitution is close to length-neutral — "him" becomes "Sam", "his" becomes
    /// "Sam's" — so the allowance is small on purpose. It is a fraction plus the name's own length
    /// rather than a flat number, because a long canonical sentence legitimately absorbs a little
    /// more variance than a five-word one, and a long *name* legitimately costs its own characters
    /// however short the sentence is.
    static let lengthSlack = 0.25

    // MARK: The check

    /// Nil when the string is safe to render.
    static func rejection(
        personalized: String,
        canonical: String,
        subject: PromptSubject
    ) -> Rejection? {
        let candidate = personalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = canonical.trimmingCharacters(in: .whitespacesAndNewlines)

        let name = subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowance = Double(source.count) * (1 + lengthSlack) + Double(name.count) * 2
        if Double(candidate.count) > allowance { return .tooLong }

        if sentenceCount(of: candidate) != sentenceCount(of: source) { return .sentenceCountChanged }

        if candidate.contains("?") != source.contains("?") { return .questionParityChanged }

        let lowered = candidate.lowercased()
        let sourceLowered = source.lowercased()
        for banned in bannedWords where lowered.contains(banned) && !sourceLowered.contains(banned) {
            return .bannedWord
        }

        // **Only when there was a name to substitute.** A child whose name has not loaded yet is
        // not a rejection reason; there is simply nothing to check.
        if !name.isEmpty, !mentions(name, in: candidate) { return .nameAbsent }

        let introduced = words(of: lowered)
            .filter { instructionVerbs.contains($0) }
            .subtracting(words(of: sourceLowered))
        if !introduced.isEmpty { return .newImperativeVerb }

        return nil
    }

    /// The whole point, in one call: the personalized string when it survives, the canonical one
    /// when it does not. **Callers never see a rejection**, which is what makes this feature
    /// invisible when it fails.
    static func accepted(
        personalized: String,
        canonical: String,
        subject: PromptSubject
    ) -> String {
        rejection(personalized: personalized, canonical: canonical, subject: subject) == nil
            ? personalized.trimmingCharacters(in: .whitespacesAndNewlines)
            : canonical
    }

    // MARK: Pieces

    /// Sentences, counted by terminator rather than by `enumerateSubstrings`.
    ///
    /// Deliberately blunt: the question is "did a sentence appear", and a count that a human can
    /// predict from looking at the string is worth more here than a linguistically correct one.
    /// A trailing terminator does not invent an empty sentence, and a string with no terminator at
    /// all is one sentence.
    static func sentenceCount(of text: String) -> Int {
        let parts = text.split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(parts.count, text.isEmpty ? 0 : 1)
    }

    /// Whether the child is actually named, as a **whole word**.
    ///
    /// `contains` is wrong here and the failure is quiet: a child called Sam matches "the **sam**e
    /// thing", Al matches "**al**ways", Bo matches "**bo**th. So a model that returned the
    /// canonical sentence untouched would be *accepted* whenever the library happened to contain
    /// the name as a substring — caching a personalization that personalized nothing.
    ///
    /// Word boundaries on both sides. The trailing one still allows a possessive, because an
    /// apostrophe is not a word character: `\bSam\b` matches "Sam's" and does not match "same".
    static func mentions(_ name: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func words(of lowercased: String) -> Set<String> {
        Set(
            lowercased
                .split(whereSeparator: { !$0.isLetter && $0 != "'" })
                .map(String.init)
        )
    }
}
