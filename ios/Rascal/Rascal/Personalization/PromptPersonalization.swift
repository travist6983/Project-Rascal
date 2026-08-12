import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Rendering a canonical mission with this child's name and pronouns, on this device, for this
/// render only.
///
/// **The canonical body is the truth and this never becomes it.** Personalized text is presentation
/// — it is never written to `prompt_body`, an assignment, an entry, or anything that syncs, and it
/// never leaves the phone. A future web client shows the canonical sentence and is not worse for
/// it; that is the architectural point of keeping the server generic.
///
/// **The model personalizes. It does not author.** Settled, not open. Substituting a name for a
/// pronoun, adjusting pronouns, adjusting a phrase the canonical text already invites — those are
/// the job. Changing what is asked, adding a step, dropping a constraint, changing the medium, or
/// adding warmth the library did not write are all failures, and a small model asked to "rewrite"
/// will do them unprompted. **So the output is checked against the input rather than trusted** —
/// see `PersonalizationGuard`.
///
/// Shaped deliberately like `Rascal/Extraction`: a plain seam every test runs against, with the
/// `FoundationModels` types quarantined behind `#if canImport` and `@available(iOS 26, *)` so the
/// whole app still compiles and runs on a deployment target where the framework does not exist.

// MARK: - Whether this phone can do it at all

/// **Not every device qualifies, and one that does not behaves identically.** Canonical text, no
/// error, no banner, no degraded-mode messaging. The same contract `ExtractionAvailability` has.
nonisolated enum PersonalizationAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// The seam over the model. Every assertion in the suite runs against a stub through this.
nonisolated protocol PromptPersonalizing: Sendable {
    func availability() async -> PersonalizationAvailability

    /// One canonical body, rendered for one child.
    ///
    /// Throws only on a genuine model failure. **Returning the canonical string unchanged is a
    /// legitimate outcome**, not an error — a prompt with nothing to personalize is common, and
    /// `PersonalizationGuard` treats "no name appeared" as a rejection precisely so that outcome
    /// costs nothing at the render.
    func personalize(
        _ canonical: String,
        for subject: PromptSubject,
        ageMonths: Int?
    ) async throws -> String
}

// MARK: - The live model

nonisolated struct DevicePromptPersonalizer: PromptPersonalizing {

    func availability() async -> PersonalizationAvailability {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .unavailable }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        // Not downloaded, no Apple Intelligence hardware, or switched off. One answer: this phone
        // shows the library's own words today, and the app says nothing about it.
        default: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    func personalize(
        _ canonical: String,
        for subject: PromptSubject,
        ageMonths: Int?
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return canonical }
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: Self.request(canonical, subject, ageMonths))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return canonical
        #endif
    }

    /// **Says what it may not do, not only what it should**, for the same reason the extractor's
    /// instructions do — and with more at stake, because this text is the thing a parent is asked
    /// to act on rather than a label on something they already wrote.
    ///
    /// The prohibitions are the validation rules restated in prose. Stating them twice is
    /// deliberate: the prompt is what makes a good outcome likely and
    /// `PersonalizationGuard` is what makes a bad one harmless.
    static let instructions = """
        You rewrite one short instruction so it names a specific child. \
        Change only the words that refer to the child: a pronoun, or a generic word like "your \
        child" or "the kid". Replace them with the child's name or the pronouns you are given. \
        Keep every other word the same. \
        Do not change what is being asked for. \
        Do not add or remove a sentence, a step, an instruction, or a condition. \
        Do not change a question into an instruction, or an instruction into a question. \
        Do not add warmth, encouragement, sentiment, or commentary. \
        Do not use the words precious, cherish, treasure, or "little moments". \
        Return only the rewritten instruction and nothing else.
        """

    /// What the child is, in the fewest words the model needs.
    ///
    /// **Pronouns are stated or the name is demanded — nothing is inferred.** An unset value is
    /// not a hint to guess from the name, and this is the sentence that stops it: with no pronouns
    /// the model is told to use the name every time, which is always grammatical and never
    /// misgenders anyone.
    static func request(_ canonical: String, _ subject: PromptSubject, _ ageMonths: Int?) -> String {
        var lines = ["The child's name is \(subject.name)."]
        if let pronouns = subject.pronouns {
            lines.append("Use \(pronouns.rawValue) pronouns for the child.")
        } else {
            lines.append(
                "The child's pronouns are not known. Use the child's name instead of any pronoun. "
                + "Do not guess a pronoun."
            )
        }
        if let ageMonths {
            lines.append("The child is \(AgeText.long(ageMonths)) old.")
        }
        lines.append("Rewrite this instruction:")
        lines.append(canonical)
        return lines.joined(separator: "\n")
    }
}
