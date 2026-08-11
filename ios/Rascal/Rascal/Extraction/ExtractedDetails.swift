import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the on-device model is allowed to produce from an entry the parent wrote.
///
/// **The model never authors mission content.** It structures, extracts, and summarizes what a
/// human wrote. It does not write prompts, it does not rewrite an entry body, and it does not
/// edit anything the parent typed — small model, weak world knowledge, and those prompts are the
/// soul of the product. Settled decision, not an open one.
///
/// This is a plain Swift type on purpose. The `@Generable` mirror lives below, behind
/// `@available(iOS 26, *)`, so the queue, the write path and every assertion in the suite compile
/// and run on a deployment target of 18.6 where `FoundationModels` does not exist.
nonisolated struct ExtractedDetails: Equatable, Sendable {
    /// Names mentioned in the body. Never inferred from context — if the parent did not write a
    /// name, there is no name.
    var people: [String] = []
    /// Where it happened, if the body says. Nil is the common case and is not a failure.
    var place: String?
    /// The mood of the moment described, not a judgment of the parent.
    var mood: String?
    var tags: [String] = []
    var summary: String?

    /// **An entry with eleven tags is worse than one with three.** Bounded here rather than in
    /// the prompt, because a model asked for "a few" will occasionally return thirty and the
    /// archive is the thing that would carry them.
    static let tagLimit = 5

    /// Everything a model returns passes through here before it is written.
    ///
    /// Trims, drops blanks, lowercases for comparison, removes duplicates, and truncates to
    /// `tagLimit`. Order is preserved so the model's own sense of importance survives.
    func normalized() -> ExtractedDetails {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            kept.append(trimmed)
            if kept.count == Self.tagLimit { break }
        }
        return ExtractedDetails(
            people: people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            place: place?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            mood: mood?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tags: kept,
            summary: summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// What actually gets written, as tags. People and place become tags too — they are the
    /// findable part, and this phase deliberately does not build a browsable index of either.
    var writableTagNames: [String] {
        var names = tags
        names.append(contentsOf: people)
        if let place { names.append(place) }
        var seen = Set<String>()
        var unique: [String] = []
        for name in names {
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(name)
        }
        return Array(unique.prefix(Self.tagLimit))
    }

    var isEmpty: Bool { writableTagNames.isEmpty }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Whether this phone can do it at all

/// **Not every device qualifies, and one that does not behaves identically minus the tags.**
/// No error, no banner, no degraded-mode messaging.
nonisolated enum ExtractionAvailability: Equatable, Sendable {
    case available
    /// Below iOS 26, no Apple Intelligence hardware, or the model is not downloaded. All the
    /// same outcome from the app's point of view: nothing happens and nothing is said.
    case unavailable
}

/// The seam over the model. Every assertion in the suite runs against a stub through this.
nonisolated protocol EntryExtracting: Sendable {
    func availability() async -> ExtractionAvailability
    /// Structure one entry body. Throws only on a genuine model failure — an entry the model has
    /// nothing to say about returns an empty `ExtractedDetails`, which is a normal outcome.
    func extract(from body: String) async throws -> ExtractedDetails
}

// MARK: - The live model

#if canImport(FoundationModels)

/// The `@Generable` mirror. **Exists only where `FoundationModels` does**, and only iOS 26+.
@available(iOS 26.0, *)
@Generable
nonisolated struct GeneratedEntryDetails {
    @Guide(description: "Names of people mentioned. Empty if the text names nobody. Never guess.")
    var people: [String]

    @Guide(description: "Where this happened, only if the text says. Empty if it does not.")
    var place: String

    @Guide(description: "One or two words for the mood of the moment described.")
    var mood: String

    @Guide(description: "Up to five short topical tags. Lowercase, one or two words each.")
    var tags: [String]

    @Guide(description: "One short sentence summarizing what happened. Use the writer's own facts.")
    var summary: String
}

@available(iOS 26.0, *)
extension GeneratedEntryDetails {
    var asDetails: ExtractedDetails {
        ExtractedDetails(
            people: people,
            place: place,
            mood: mood,
            tags: tags,
            summary: summary
        ).normalized()
    }
}

#endif

/// The real extractor.
///
/// Deliberately behind `EntryExtracting` so a hard task could later be routed elsewhere without
/// touching a call site — the phase asks for that option to stay open, so nothing above this
/// line knows what `LanguageModelSession` is.
nonisolated struct DeviceEntryExtractor: EntryExtracting {

    func availability() async -> ExtractionAvailability {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .unavailable }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        // Not downloaded yet, no Apple Intelligence hardware, or switched off. All the same
        // answer here: this phone does not do it today, and the app says nothing about it.
        default: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    func extract(from body: String) async throws -> ExtractedDetails {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return ExtractedDetails() }
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: body,
            generating: GeneratedEntryDetails.self
        )
        return response.content.asDetails
        #else
        return ExtractedDetails()
        #endif
    }

    /// **Says what it may not do, not only what it should.** A small model given a parent's
    /// sentence about their kid will happily improve it if not told otherwise, and the parent's
    /// words are the archive.
    static let instructions = """
        You label a short note a parent wrote about their child. \
        Extract only what the note actually says. \
        Do not invent names, places, or events. \
        Do not rewrite, improve, correct, or continue the parent's words. \
        Do not write advice, encouragement, or commentary. \
        If the note does not mention something, leave that field empty.
        """
}
