import Foundation
import SwiftData
import Testing

@testable import Rascal

// MARK: - The stub

/// Stands in for the model. **Every assertion in this file is about the seam, not about model
/// quality** — the model has never returned `.available` on any hardware this project has.
///
/// Locking is confined to synchronous helpers, the shape `StubPerformer` uses, because taking a
/// lock inside an `async` function is a warning and this lane treats a warning as a defect.
final class StubPersonalizer: PromptPersonalizing, @unchecked Sendable {
    /// A string no library prompt contains, so a store can be searched for it. If this ever turns
    /// up in a persisted row, personalized text reached disk.
    static let sentinel = "ZZSENTINELZZ"

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _availability: PersonalizationAvailability = .available
    private var _reply: (@Sendable (String) -> String)?
    private var _failure: (any Error)?

    init(
        availability: PersonalizationAvailability = .available,
        reply: (@Sendable (String) -> String)? = nil,
        failure: (any Error)? = nil
    ) {
        _availability = availability
        _reply = reply
        _failure = failure
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var callCount: Int { calls.count }

    private func record(_ canonical: String) -> (PersonalizationAvailability, String, (any Error)?) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(canonical)
        return (_availability, _reply?(canonical) ?? canonical, _failure)
    }

    private func currentAvailability() -> PersonalizationAvailability {
        lock.lock(); defer { lock.unlock() }
        return _availability
    }

    func availability() async -> PersonalizationAvailability { currentAvailability() }

    func personalize(
        _ canonical: String,
        for subject: PromptSubject,
        ageMonths: Int?
    ) async throws -> String {
        let (_, reply, failure) = record(canonical)
        if let failure { throw failure }
        return reply
    }
}

private enum StubFailure: Error { case modelDied }

private let sam = PromptSubject(name: "Sam", pronouns: .heHim)
private let unnamed = PromptSubject(name: "", pronouns: nil)

// MARK: - The guard

@Suite("Personalization — the guard")
struct PersonalizationGuardTests {

    private let canonical = "Record him telling you about his day."

    private func rejection(_ personalized: String, _ source: String? = nil) -> PersonalizationGuard.Rejection? {
        PersonalizationGuard.rejection(
            personalized: personalized, canonical: source ?? canonical, subject: sam
        )
    }

    @Test("the job itself is accepted")
    func theActualJobPasses() {
        #expect(rejection("Record Sam telling you about his day.") == nil)
    }

    @Test("a materially longer string is rejected")
    func tooLongIsRejected() {
        #expect(
            rejection("Record Sam telling you all about his whole entire day, everything he did, "
                      + "start to finish, in as much detail as he will give you.") == .tooLong
        )
    }

    /// An added sentence is an added instruction, which is a different mission.
    /// A longer canonical on purpose: an added sentence always adds length, so against a short
    /// source `tooLong` fires first and this rule never gets a turn. That ordering is correct —
    /// both are rejections — but a test for the sentence rule has to give it something to reject.
    @Test("an added sentence is rejected")
    func addedSentenceIsRejected() {
        let long = "Record him telling you about his day, start to finish, in his own words."
        #expect(
            PersonalizationGuard.rejection(
                personalized: "Record Sam telling you about his day, start to finish, in his own words. Then wait.",
                canonical: long,
                subject: sam
            ) == .sentenceCountChanged
        )
    }

    @Test("turning an instruction into a question is rejected, and the reverse")
    func questionParityIsEnforced() {
        #expect(rejection("Will Sam tell you about his day?") == .questionParityChanged)
        #expect(
            PersonalizationGuard.rejection(
                personalized: "Write down what Sam said.",
                canonical: "What did he say today?",
                subject: sam
            ) == .questionParityChanged
        )
    }

    @Test("tone words the library does not use are rejected")
    func bannedWordsAreRejected() {
        #expect(rejection("Record Sam telling you about his precious day.") == .bannedWord)
        #expect(rejection("Record Sam telling you about his day. ") == nil, "trailing space is not a rejection")
    }

    /// If the name never appeared, the call achieved nothing and canonical is equivalent — and
    /// cheaper, and already on screen.
    @Test("a string that never mentions the child is rejected")
    func nameMustAppear() {
        #expect(rejection("Record him telling you about his day.") == .nameAbsent)
    }

    /// **A substring is not a mention.** `contains` accepts a model that changed nothing whenever
    /// the library happens to hold the name inside another word — Sam in "the same thing", Al in
    /// "always", Bo in "both" — and caches a personalization that personalized nothing.
    @Test("the name must appear as a word, not as a substring")
    func nameMustBeAWholeWord() {
        #expect(PersonalizationGuard.mentions("Sam", in: "the same thing") == false)
        #expect(PersonalizationGuard.mentions("Al", in: "always ask") == false)
        #expect(PersonalizationGuard.mentions("Bo", in: "both of them") == false)
        // A possessive is still a mention: an apostrophe is not a word character.
        #expect(PersonalizationGuard.mentions("Sam", in: "Sam's hands"))
        #expect(PersonalizationGuard.mentions("Sam", in: "Photograph Sam."))

        // And the rule that uses it: canonical contains "same", the model changed nothing.
        #expect(
            PersonalizationGuard.rejection(
                personalized: "What is the same thing he does every morning?",
                canonical: "What is the same thing he does every morning?",
                subject: sam
            ) == .nameAbsent
        )
    }

    @Test("a new instruction verb is rejected")
    func newImperativeIsRejected() {
        // Same length, same sentence count, name present — only the task changed.
        #expect(rejection("Photograph Sam telling about his day.") == .newImperativeVerb)
    }

    /// The rules must not fire on the thing they exist to allow.
    @Test("pronoun-only adjustment with no name is still rejected, but she/her substitution passes")
    func pronounAdjustmentPasses() {
        let sky = PromptSubject(name: "Sky", pronouns: .theyThem)
        #expect(
            PersonalizationGuard.rejection(
                personalized: "Record Sky telling you about their day.",
                canonical: canonical,
                subject: sky
            ) == nil
        )
    }

    @Test("accepted() hands back canonical on any rejection, never an empty string")
    func acceptedFallsBackToCanonical() {
        let bad = "Record Sam telling you about his day. And write it down."
        #expect(
            PersonalizationGuard.accepted(personalized: bad, canonical: canonical, subject: sam)
                == canonical
        )
        #expect(
            PersonalizationGuard.accepted(personalized: "", canonical: canonical, subject: sam)
                == canonical
        )
    }

    @Test("sentence counting is what a human would count")
    func sentenceCounting() {
        #expect(PersonalizationGuard.sentenceCount(of: "One.") == 1)
        #expect(PersonalizationGuard.sentenceCount(of: "One. Two.") == 2)
        #expect(PersonalizationGuard.sentenceCount(of: "No terminator") == 1)
        #expect(PersonalizationGuard.sentenceCount(of: "") == 0)
    }
}

// MARK: - The center

@MainActor
@Suite("Personalization — the center")
struct PersonalizationCenterTests {

    private let canonical = "Record him telling you about his day."

    @Test("an unavailable model renders canonical, with no error and no call")
    func unavailableRendersCanonical() async {
        let stub = StubPersonalizer(availability: .unavailable, reply: { _ in "Record Sam's day." })
        let center = PersonalizationCenter(personalizer: stub)
        let id = UUID()

        // Already correct before anything is requested — this is the never-blocks property.
        #expect(center.text(for: id, canonical: canonical) == canonical)
        await center.request(assignmentId: id, canonical: canonical, subject: sam, ageMonths: 49)

        #expect(center.text(for: id, canonical: canonical) == canonical)
        #expect(stub.callCount == 0, "an unavailable model is never asked")
    }

    @Test("an accepted personalization replaces the canonical text")
    func acceptedTextIsUsed() async {
        let stub = StubPersonalizer(reply: { _ in "Record Sam telling you about his day." })
        let center = PersonalizationCenter(personalizer: stub)
        let id = UUID()

        await center.request(assignmentId: id, canonical: canonical, subject: sam, ageMonths: 49)

        #expect(center.text(for: id, canonical: canonical) == "Record Sam telling you about his day.")
    }

    @Test("a rejected personalization leaves canonical on screen, not an empty or partial string")
    func rejectedFallsBackToCanonical() async {
        let stub = StubPersonalizer(reply: { _ in "Record Sam's day. Then write down what he said." })
        let center = PersonalizationCenter(personalizer: stub)
        let id = UUID()

        await center.request(assignmentId: id, canonical: canonical, subject: sam, ageMonths: 49)

        #expect(center.text(for: id, canonical: canonical) == canonical)
        #expect(center.isPersonalized(id, canonical: canonical) == false)
        #expect(center.rejections[.sentenceCountChanged] == 1)
    }

    @Test("a model that throws leaves canonical on screen")
    func failureFallsBackToCanonical() async {
        let stub = StubPersonalizer(failure: StubFailure.modelDied)
        let center = PersonalizationCenter(personalizer: stub)
        let id = UUID()

        await center.request(assignmentId: id, canonical: canonical, subject: sam, ageMonths: 49)

        #expect(center.text(for: id, canonical: canonical) == canonical)
    }

    /// A SwiftUI body runs many times for one board. The model must not.
    @Test("the model is called once per assignment, not once per render")
    func oncePerAssignment() async {
        let stub = StubPersonalizer(reply: { _ in "Record Sam telling you about his day." })
        let center = PersonalizationCenter(personalizer: stub)
        let id = UUID()

        for _ in 0..<8 {
            await center.request(assignmentId: id, canonical: canonical, subject: sam, ageMonths: 49)
        }

        #expect(stub.callCount == 1)
    }

    /// **Concurrent renders, which is the real case.** `oncePerAssignment` above calls in
    /// sequence, and a sequential test cannot see a claim made across a suspension point.
    ///
    /// Two cards for the same assignment — or one card whose body re-runs while the first request
    /// is still out — both reach `request` before either has finished. If the in-flight claim is
    /// made *after* an `await`, both pass the check and both call the model. This is the bug
    /// `APIClient.refreshSession` documents at length and `SyncEngine` cites: an async function
    /// may suspend between statements containing no visible `await`, so a check-then-act written
    /// across a suspension point is not atomic however atomic it reads.
    @Test("concurrent requests for one assignment still call the model once")
    func concurrentRequestsCallOnce() async {
        let stub = StubPersonalizer(reply: { _ in "Record Sam telling you about his day." })
        let center = PersonalizationCenter(personalizer: stub)
        let id = UUID()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { @MainActor in
                    await center.request(
                        assignmentId: id, canonical: self.canonical, subject: sam, ageMonths: 49
                    )
                }
            }
        }

        #expect(stub.callCount == 1, "the model was asked \(stub.callCount) times for one assignment")
    }

    /// **The canonical body is part of the key.** A library edit must not render yesterday's
    /// sentence for today's prompt.
    @Test("a changed canonical body invalidates the cached personalization")
    func canonicalChangeInvalidates() async {
        let stub = StubPersonalizer(reply: { _ in "Record Sam telling you about his day." })
        let center = PersonalizationCenter(personalizer: stub)
        let id = UUID()

        await center.request(assignmentId: id, canonical: canonical, subject: sam, ageMonths: 49)
        #expect(center.isPersonalized(id, canonical: canonical))

        let edited = "Record him telling you about his week."
        #expect(center.text(for: id, canonical: edited) == edited, "the old string must not be reused")
        #expect(center.isPersonalized(id, canonical: edited) == false)
    }

    /// **Nothing is inferred from a name.** An unset pronoun means the model is told to use the
    /// name, and a guessed pronoun never reaches the guard because the request never asks for one.
    @Test("an unset pronoun asks for the name and never a guessed pronoun")
    func unsetPronounsUseTheName() {
        let unset = PromptSubject(name: "Sky", pronouns: nil)
        let request = DevicePromptPersonalizer.request(canonical, unset, 49)

        #expect(request.contains("pronouns are not known"))
        #expect(request.contains("Do not guess a pronoun."))
        #expect(request.contains("Sky"))
        for set in PronounSet.allCases {
            #expect(request.contains("Use \(set.rawValue) pronouns") == false, "no pronoun was assumed")
        }
    }

    @Test("a known pronoun is stated rather than left to the model")
    func knownPronounsAreStated() {
        let request = DevicePromptPersonalizer.request(canonical, sam, 49)
        #expect(request.contains("Use he/him pronouns"))
    }

    /// A child whose name has not loaded yet is not worth a round trip: the model would return the
    /// canonical sentence and the guard would reject it for exactly that.
    @Test("a child with no name yet is never sent to the model")
    func noNameNoCall() async {
        let stub = StubPersonalizer()
        let center = PersonalizationCenter(personalizer: stub)

        await center.request(assignmentId: UUID(), canonical: canonical, subject: unnamed, ageMonths: nil)

        #expect(stub.callCount == 0)
    }

    @Test("the rejection rate is observable")
    func rejectionRateIsReported() async {
        let stub = StubPersonalizer(reply: { _ in "Record Sam's day. Then write it down." })
        let center = PersonalizationCenter(personalizer: stub)

        await center.request(assignmentId: UUID(), canonical: canonical, subject: sam, ageMonths: nil)

        #expect(center.rejectionRate == 1.0)
    }
}

// MARK: - One board, one sentence

@MainActor
@Suite("Personalization — the board agrees with itself")
struct PersonalizationConsistencyTests {

    /// **The undo toast quotes the sentence the card was showing**, which since this phase may be
    /// the personalized one. Its own comment says so: "it has to be the same sentence the card was
    /// showing a moment ago".
    @Test("the skip toast quotes the personalized sentence, not the library's")
    func toastQuotesWhatWasOnScreen() throws {
        let assignment = try APIClient.decoder.decode(
            AssignmentResponse.self,
            from: Data("""
            {"id":"\(UUID().uuidString)","prompt_id":"\(UUID().uuidString)","slot":"mission",
             "body":"Record him telling you about his day.","kind":"audio",
             "completion_mode":"audio","status":"open","assigned_on":"2026-08-11",
             "expires_on":"2026-08-18","is_custom":false,"unlock_at_age":null}
            """.utf8)
        )
        let skip = TodayModel.PendingSkip(assignment: assignment)

        #expect(skip.label(for: sam).contains("him"), "with nothing personalized it is the library's")
        #expect(
            skip.label(for: sam, personalized: "Record Sam telling you about his day.")
                == "Skipped “Record Sam telling you about his day”"
        )
    }

    /// Truncation happens **after** personalization, never before — shortening first would count
    /// the library's words towards the 60 and quote back a sentence nobody saw.
    @Test("a long personalized sentence is truncated after substitution")
    func truncationFollowsPersonalization() throws {
        let long = String(repeating: "a", count: 80)
        let assignment = try APIClient.decoder.decode(
            AssignmentResponse.self,
            from: Data("""
            {"id":"\(UUID().uuidString)","prompt_id":"\(UUID().uuidString)","slot":"mission",
             "body":"short body","kind":"audio","completion_mode":"audio","status":"open",
             "assigned_on":"2026-08-11","expires_on":"2026-08-18","is_custom":false,
             "unlock_at_age":null}
            """.utf8)
        )
        let label = TodayModel.PendingSkip(assignment: assignment)
            .label(for: sam, personalized: long)

        #expect(label.contains("…"), "the personalized string was the one measured")
        #expect(label.contains(String(repeating: "a", count: 57)))
    }
}

// MARK: - Never persisted

/// **The rule this phase most needs to keep**, and the one most likely to pass vacuously: a test
/// that inspects a write path nothing actually uses proves nothing.
///
/// So this does not inspect a path. It personalizes, then searches **the whole store** — every
/// entry, every assignment, every media row — for a sentinel string that exists nowhere in the
/// library. If personalized text can reach disk by any route these types offer, the sentinel is
/// the thing that turns up.
@MainActor
@Suite("Personalization — never persisted")
struct PersonalizationPersistenceTests {

    private let canonical = "Record him telling you about his day."

    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Every string the store holds, from every model in the schema.
    private func allStoredStrings(_ context: ModelContext) throws -> [String] {
        var found: [String] = []
        for entry in try context.fetch(FetchDescriptor<Entry>()) {
            found.append(contentsOf: [entry.title, entry.body, entry.promptBody].compactMap { $0 })
            found.append(contentsOf: entry.tagNames)
        }
        for assignment in try context.fetch(FetchDescriptor<Assignment>()) {
            found.append(assignment.body)
        }
        for media in try context.fetch(FetchDescriptor<Media>()) {
            found.append(contentsOf: [media.transcript, media.caption].compactMap { $0 })
        }
        return found
    }

    @Test("a personalized string reaches no row in the store")
    func personalizedTextIsNeverPersisted() async throws {
        let context = try context()
        let entryId = UUID()

        // A real entry, cached the way the app caches one, carrying the canonical prompt.
        EntryCache.upsert(
            try decodeEntry(entryJSON(
                id: entryId, childId: UUID(), occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: UUID(), kind: "audio", duration: 30)],
                prompt: canonical
            )),
            into: context
        )
        try context.save()

        // Personalize it, with a reply carrying a string the library could never contain.
        let personalized = "Record Sam \(StubPersonalizer.sentinel) about his day."
        let stub = StubPersonalizer(reply: { _ in personalized })
        let center = PersonalizationCenter(personalizer: stub)
        let assignmentId = UUID()
        await center.request(
            assignmentId: assignmentId, canonical: canonical, subject: sam, ageMonths: 49
        )

        // It is on screen…
        #expect(center.text(for: assignmentId, canonical: canonical) == personalized)
        // …and nowhere in the store.
        let stored = try allStoredStrings(context)
        #expect(stored.isEmpty == false, "the fixture must actually have written something")
        for value in stored {
            #expect(
                value.contains(StubPersonalizer.sentinel) == false,
                "personalized text reached a persisted row: \(value)"
            )
        }
        // And the row still carries the library's own sentence.
        #expect(EntryCache.entry(id: entryId, in: context)?.promptBody == canonical)
    }

    /// **A sealed letter still shows the prompt it answered** — phase 22 pinned that, and it is
    /// deliberate: the prompt is the library's sentence, not the sealed content. But it must not be
    /// *personalized*, because personalization is scoped to assignments a parent is being asked to
    /// act on today, and an entry's stored prompt is archive text.
    ///
    /// Structurally this cannot happen: `EntryCardModel` is a pure value type with no environment
    /// and no center, so it has nowhere to call. This pins the behaviour so that wiring one in
    /// later has to break a test with the reason written on it.
    @Test("an entry's prompt is never personalized, sealed or otherwise")
    func entryPromptsAreNeverPersonalized() async throws {
        let stub = StubPersonalizer(reply: { _ in "Record Sam \(StubPersonalizer.sentinel)." })
        let center = PersonalizationCenter(personalizer: stub)
        let canonicalPrompt = "Write him one thing about money you wish you had been told."

        let sealed = try cachedEntry(
            type: "text", body: "Money is mostly patience.", title: "A letter",
            unlockAtAge: 18, prompt: canonicalPrompt
        )
        let ordinary = try cachedEntry(
            type: "text", body: "He called it a hangaburger.", prompt: canonicalPrompt
        )

        let sealedCard = EntryCardModel(entry: sealed, media: [])
        let ordinaryCard = EntryCardModel(entry: ordinary, media: [])

        // The library's own sentence, on both, untouched.
        #expect(sealedCard.prompt == canonicalPrompt)
        #expect(ordinaryCard.prompt == canonicalPrompt)
        #expect(sealedCard.prompt?.contains(StubPersonalizer.sentinel) == false)
        // And the sealed one is still sealed, so nothing else about it leaked either.
        #expect(sealedCard.isSealed)
        #expect(sealedCard.preview == nil)
        // Nothing asked the model. Card models have no route to one.
        #expect(stub.callCount == 0)
        #expect(center.isPersonalized(UUID(), canonical: canonicalPrompt) == false)
    }

    /// The widget snapshot is a **file** in the App Group, which is disk — so it carries canonical
    /// text by the same rule, and the extension has no model to personalize it with anyway.
    ///
    /// Asserted behaviourally rather than by reading the source: the snapshot's prompt line must
    /// be exactly what `PromptTokens.render` produces, which is the deterministic substitution and
    /// nothing further.
    /// **The adjacency Phase E flagged.** `ComposerView` renders the personalized header three
    /// lines above the line that writes `entry.promptBody`, and that field syncs. This pins that
    /// the write takes the assignment's canonical body, so a future edit that "reuses the sentence
    /// already on screen" fails here rather than in someone's archive.
    @Test("the composer writes the canonical prompt to the entry, never the personalized one")
    func composerPersistsCanonical() async throws {
        let context = try context()
        let canonicalBody = "Record him telling you about his day."
        let personalized = "Record Sam \(StubPersonalizer.sentinel) about his day."

        let center = PersonalizationCenter(personalizer: StubPersonalizer(reply: { _ in personalized }))
        let assignmentId = UUID()
        await center.request(
            assignmentId: assignmentId, canonical: canonicalBody, subject: sam, ageMonths: 49
        )
        #expect(center.text(for: assignmentId, canonical: canonicalBody) == personalized)

        // What the composer actually writes, in the shape it writes it.
        let entry = Entry(
            id: UUID(), childId: UUID(), assignmentId: assignmentId,
            occurredAt: Date(), title: nil, body: "he told me about the pond", unlockAtAge: nil
        )
        entry.promptBody = canonicalBody
        context.insert(entry)
        try context.save()

        let stored = try #require(try context.fetch(FetchDescriptor<Entry>()).first)
        #expect(stored.promptBody == canonicalBody)
        #expect(stored.promptBody?.contains(StubPersonalizer.sentinel) == false)
        #expect(stored.promptBody?.contains("Sam") == false)
    }

    @Test("the widget snapshot carries token-rendered canonical text and nothing more")
    func widgetSnapshotIsCanonical() throws {
        let body = "Record him telling you about his day."
        let today = "2026-08-11"
        let assignment = try APIClient.decoder.decode(
            AssignmentResponse.self,
            from: Data("""
            {"id":"\(UUID().uuidString)","prompt_id":"\(UUID().uuidString)","slot":"mission",
             "body":"\(body)","kind":"audio","completion_mode":"audio","status":"open",
             "assigned_on":"\(today)","expires_on":"2026-08-18","is_custom":false,
             "unlock_at_age":null}
            """.utf8)
        )
        let board = TodayBoard.merge(
            response: TodayResponse(
                date: today,
                child: ChildSummary(id: UUID(), name: "Sam Terry", ageMonths: 50),
                today: [assignment], waiting: [], doneToday: []
            ),
            entries: [], media: []
        )
        let subject = PromptSubject(name: "Sam", pronouns: .heHim)

        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board, familyTimezone: "America/Denver", subject: subject
        )

        // This library body carries no tokens, so the deterministic render is identity — which is
        // exactly why the file must not contain "Sam".
        #expect(PromptTokens.render(body, for: subject) == body)
        #expect(snapshot.mission?.body == body, "the snapshot is the canonical sentence")
        #expect(
            snapshot.mission?.body.contains("Sam") == false,
            "no personalized text reached the App Group file"
        )
    }
}
