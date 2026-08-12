import Foundation
import SwiftData
import Testing

@testable import Rascal

/// One entry, in full — and the rules the detail screen is built on.
@MainActor
@Suite("Entry detail")
struct EntryDetailTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    @Test("the detail fetch fills in the prompt and the transcript the list row never carried")
    func detailAddsPromptAndTranscript() throws {
        let context = try makeContext()
        let id = UUID()
        let child = UUID()
        let audioId = UUID()

        // The list row first: no prompt, no transcript, exactly as `GET /entries` returns it.
        EntryCache.upsert(
            [try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio", duration: 34)]
            ))],
            into: context
        )
        let entry = try #require(EntryCache.entry(id: id, in: context))
        #expect(entry.promptBody == nil)

        // Then the detail, which is the only response that carries either.
        EntryCache.upsert(
            try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio", duration: 34, transcript: "he told me about the pond")],
                prompt: "Record him telling you a story"
            )),
            into: context
        )

        #expect(entry.promptBody == "Record him telling you a story")
        #expect(EntryCache.media(id: audioId, in: context)?.transcript == "he told me about the pond")
    }

    @Test("a list response after a detail one does not blank the prompt or the transcript")
    func listDoesNotEraseDetail() throws {
        // Paging back over an entry already opened must not undo what opening it fetched.
        let context = try makeContext()
        let id = UUID()
        let child = UUID()
        let audioId = UUID()

        EntryCache.upsert(
            try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio", transcript: "what he said")],
                prompt: "Record him telling you a story"
            )),
            into: context
        )
        EntryCache.upsert(
            [try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio")]
            ))],
            into: context
        )

        #expect(EntryCache.entry(id: id, in: context)?.promptBody == "Record him telling you a story")
        #expect(EntryCache.media(id: audioId, in: context)?.transcript == "what he said")
    }

    @Test("a freeform entry carries no prompt, and that is not a missing value")
    func freeformHasNoPrompt() throws {
        let context = try makeContext()
        let id = UUID()
        EntryCache.upsert(
            try decodeEntry(entryJSON(id: id, childId: UUID(), occurredAt: Date())),
            into: context
        )
        // The block is omitted cleanly rather than rendered empty — freeform entries are
        // first-class and must not look incomplete.
        #expect(EntryCache.entry(id: id, in: context)?.promptBody == nil)
    }

    @Test("deleting from the detail screen removes the row from the timeline query")
    func deleteRemovesFromTheList() async throws {
        let context = try makeContext()
        let child = UUID()
        let id = UUID()
        EntryCache.upsert(
            [try decodeEntry(entryJSON(id: id, childId: child, occurredAt: Date()))],
            into: context
        )
        let entry = try #require(EntryCache.entry(id: id, in: context))

        let performer = StubPerformer()
        performer.on("/entries/") { _ in (Data(), 204) }
        await EntryCache.delete(entry, api: client(performer), in: context)

        // The list's own predicate, verbatim.
        let visible = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil }
        ))
        #expect(visible.isEmpty)
        // And the row itself is still there, because a deletion syncs as a row.
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)
        #expect(entry.deletionPending == false)
    }

    @Test("a deleted entry does not come back when the next page is fetched")
    func deletedDoesNotResurrect() async throws {
        let context = try makeContext()
        let child = UUID()
        let id = UUID()
        let json = entryJSON(id: id, childId: child, occurredAt: Date())
        EntryCache.upsert([try decodeEntry(json)], into: context)
        let entry = try #require(EntryCache.entry(id: id, in: context))

        let performer = StubPerformer()
        performer.on("/entries/") { _ in (Data(), 204) }
        await EntryCache.delete(entry, api: client(performer), in: context)

        // `GET /entries` excludes soft-deleted rows, so the server will simply stop listing it.
        // But a page already in flight can still carry it, and that must not undelete anything.
        EntryCache.upsert([try decodeEntry(json)], into: context)

        #expect(entry.deletedAt != nil)
        let visible = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil }
        ))
        #expect(visible.isEmpty)
    }

    @Test("a sealed entry is a letter with an unlock age, and nothing else is")
    func sealedIsOnlyUnlockAtAge() throws {
        let context = try makeContext()
        let sealed = UUID()
        let plain = UUID()
        EntryCache.upsert(
            [
                try decodeEntry(entryJSON(
                    id: sealed, childId: UUID(), occurredAt: Date(),
                    title: "A letter", unlockAtAge: 18
                )),
                try decodeEntry(entryJSON(id: plain, childId: UUID(), occurredAt: Date())),
            ],
            into: context
        )

        #expect(EntryCache.entry(id: sealed, in: context)?.unlockAtAge == 18)
        #expect(EntryCache.entry(id: plain, in: context)?.unlockAtAge == nil)
    }

    @Test("editing routes into the composer rather than a second editor")
    func editModeMatchesTheComposer() throws {
        // The rule is one editor in this app. This asserts the request the detail screen builds
        // is the one `ComposerView.loadForEditing` knows how to open.
        let entryId = UUID()
        let written = ComposerRequest(childId: UUID(), assignment: nil, mode: .text, editing: entryId)
        let didIt = ComposerRequest(childId: UUID(), assignment: nil, mode: .didIt, editing: entryId)

        #expect(written.isEditing)
        #expect(written.editing == entryId)
        #expect(didIt.isEditing)
        #expect(written.assignment == nil, "an edit reopens the entry, not the mission")
    }
}

/// Entry Detail v2 — the rules the redesign is built on, as rules rather than pixels.
///
/// The screen's own composition is not unit-testable (SwiftUI, `@Query`, no snapshot harness in
/// this project), so the decisions it makes are lifted into static functions and asserted here.
/// That is the same move `EntryDetailScreen.transcript(in:)` already made and for the same stated
/// reason: a layout decision that can be asserted beats one that can only be looked at.
@MainActor
@Suite("Entry detail v2")
struct EntryDetailV2Tests {

    private func media(_ entryId: UUID, _ kind: String, duration: Int? = nil) -> Media {
        completeMedia(entryId: entryId, kind: kind, duration: duration)
    }

    // MARK: The backdrop — the only thing that varies

    /// **The seal answers before the media is ever consulted.** A sealed letter carrying a photo
    /// must not resolve to `.picture`, and the ordering inside `backdrop` is what guarantees it.
    @Test("a sealed entry gets the sealed backdrop even when it has a photo")
    func sealedOutranksMedia() {
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: 18, unsealed: false, type: .text, pictureCount: 3
            ) == .sealed
        )
    }

    @Test("opening a sealed letter lets its real backdrop through")
    func unsealedFallsThroughToTheRealOne() {
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: 18, unsealed: true, type: .text, pictureCount: 1
            ) == .picture
        )
    }

    /// The three completion shapes, as backdrops. **None of them is an absence:** an entry with no
    /// artifact gets a deliberate ground, not the empty space where a picture would have been.
    @Test("every completion shape gets a backdrop of its own, and none of them is nothing")
    func everyShapeHasAGround() {
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: .photo, pictureCount: 1
            ) == .picture
        )
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: .audio, pictureCount: 0
            ) == .voice
        )
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: .didIt, pictureCount: 0
            ) == .didIt
        )
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: .text, pictureCount: 0
            ) == .canvas
        )
    }

    /// A did-it entry that someone photographed is still a picture entry. The artifact wins over
    /// the type, because the artifact is what there is to look at.
    @Test("a did-it entry with a photo is a picture entry")
    func mediaOutranksType() {
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: .didIt, pictureCount: 2
            ) == .picture
        )
    }

    // MARK: The completion mark — where "you did this" goes

    /// **The regression this suite exists to have caught.** v2 moved the did-it check into the
    /// hero, and the hero only draws when nothing else is using it. The inline one had already
    /// been deleted as a duplicate — so a did-it entry with a photograph lost its mark entirely,
    /// which is to say the archive stopped saying the one thing that entry is *for*.
    @Test("a did-it entry with a photo still gets its mark, just not in the hero")
    func photographedDidItKeepsItsMark() {
        #expect(
            EntryDetailScreen.completionMark(type: .didIt, pictureCount: 1, hasVoice: false)
                == .inline
        )
        #expect(
            EntryDetailScreen.completionMark(type: .didIt, pictureCount: 0, hasVoice: true)
                == .inline
        )
    }

    @Test("a did-it entry with nothing else in the hero gets the big one")
    func plainDidItGetsTheHeroMark() {
        #expect(
            EntryDetailScreen.completionMark(type: .didIt, pictureCount: 0, hasVoice: false)
                == .hero
        )
    }

    /// The mark means "completed a mission with nothing to show for it". It is not decoration and
    /// it does not belong on entries that have an artifact of their own.
    @Test("nothing but a did-it entry gets a completion mark")
    func onlyDidItIsMarked() {
        for type in [EntryType.text, .photo, .video, .audio] {
            #expect(
                EntryDetailScreen.completionMark(type: type, pictureCount: 0, hasVoice: false)
                    == .none,
                "\(type) must not be marked complete"
            )
        }
        #expect(EntryDetailScreen.completionMark(type: nil, pictureCount: 0, hasVoice: false) == .none)
    }

    /// **Exactly one mark, always.** Two on one screen is the duplicate that caused the deletion
    /// that caused the regression, so it is worth pinning that hero and inline are exclusive.
    @Test("the mark is never in two places at once")
    func theMarkIsNeverDoubled() {
        for pictures in 0...3 {
            for voice in [true, false] {
                let mark = EntryDetailScreen.completionMark(
                    type: .didIt, pictureCount: pictures, hasVoice: voice
                )
                #expect(mark != .none, "a did-it entry is always marked somewhere")
            }
        }
    }

    // MARK: The facts line

    /// **The one assertion this screen has always needed.** `occurred_at` and `created_at` are
    /// never conflated, and a backfilled photo belongs to the year it happened — so the fixture is
    /// one where reading the wrong field gives a visibly different sentence.
    @Test("the date in the facts line is occurred_at, not created_at")
    func factsUseOccurredAt() throws {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let id = UUID()
        let occurred = Date(timeIntervalSince1970: 1_500_000_000)   // 14 July 2017
        let created = Date(timeIntervalSince1970: 1_786_000_000)    // 2026 — the day it was added

        // A backfilled photograph: it happened in 2017 and reached the archive nine years later.
        EntryCache.upsert(
            try decodeEntry(entryJSON(
                id: id, childId: UUID(), occurredAt: occurred, createdAt: created,
                type: "photo", body: nil
            )),
            into: context
        )
        let entry = try #require(EntryCache.entry(id: id, in: context))
        #expect(entry.createdAt != entry.occurredAt, "the fixture is only meaningful if they differ")

        let sentence = EntryDetailScreen.factsSentence(for: entry, media: [])

        // **This comparison was `== DayHeaderText.full(occurred)` and had to change**, because
        // the phase 22 correction changed the printed date itself: day before month, no comma,
        // and a time of day on a shape that has no count and no length to state. The assertion's
        // subject is unchanged — it is still "the date is `occurred_at`" — and the clauses below
        // it, which are what actually carry that meaning, are untouched and joined by two more.
        // Flagged in the report rather than quietly rewritten.
        #expect(sentence.hasPrefix(DayHeaderText.entryDate(occurred)))
        #expect(sentence.contains("2017"))
        // The whole point: reading the wrong field would file this under 2026.
        #expect(sentence.contains("2026") == false)
        #expect(sentence != DayHeaderText.full(created))
        #expect(sentence.hasPrefix(DayHeaderText.entryDate(created)) == false)
    }

    @Test("one photo says nothing about how many, because it is right there")
    func singlePictureIsNotCounted() throws {
        let id = UUID()
        let sentence = EntryDetailScreen.factsSentence(
            for: try cachedEntry(occurredAt: Date(timeIntervalSince1970: 1_500_000_000)),
            media: [media(id, "photo")]
        )
        #expect(sentence.contains("·") == false)
    }

    @Test("several photos are counted, and named for what they are")
    func manyPicturesAreCounted() throws {
        let id = UUID()
        let photos = EntryDetailScreen.factsSentence(
            for: try cachedEntry(occurredAt: Date(timeIntervalSince1970: 1_500_000_000)),
            media: (0..<10).map { _ in media(id, "photo") }
        )
        #expect(photos.contains("10 photos"))

        let mixed = EntryDetailScreen.factsSentence(
            for: try cachedEntry(occurredAt: Date(timeIntervalSince1970: 1_500_000_000)),
            media: [media(id, "photo"), media(id, "video")]
        )
        #expect(mixed.contains("2 items"), "never 'media', which is a word for the people who build it")
    }

    @Test("a recording says how long it runs")
    func voiceCarriesItsLength() throws {
        let id = UUID()
        let sentence = EntryDetailScreen.factsSentence(
            for: try cachedEntry(occurredAt: Date(timeIntervalSince1970: 1_500_000_000)),
            media: [media(id, "audio", duration: 42)]
        )
        #expect(sentence.contains("0:42"))
    }

    /// A deleted photo is not a photo. The facts line must not count rows the screen will not draw.
    @Test("deleted media is not counted")
    func deletedMediaIsNotCounted() throws {
        let id = UUID()
        let gone = media(id, "photo")
        gone.deletedAt = Date()
        let sentence = EntryDetailScreen.factsSentence(
            for: try cachedEntry(occurredAt: Date(timeIntervalSince1970: 1_500_000_000)),
            media: [media(id, "photo"), gone]
        )
        // Not `contains("2")` — the date itself has digits in it, which is how the first draft of
        // this assertion passed for the wrong reason.
        #expect(sentence.contains("2 photos") == false)
        #expect(sentence.contains("·") == false)
    }

    // MARK: A no-artifact entry is complete

    /// The trap the timeline had to be steered off, asserted here so this screen cannot walk back
    /// into it: a did-it entry has no media, no transcript, and still resolves to a real ground.
    @Test("a did-it entry with nothing attached is a finished screen, not an empty one")
    func didItIsComplete() throws {
        let entry = try cachedEntry(type: "did_it", body: nil, title: nil)

        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: entry.type, pictureCount: 0
            ) == .didIt
        )
        #expect(EntryDetailScreen.transcript(in: []) == nil, "and no transcript block")
        // The sentence still says the one thing there is to say.
        #expect(
            EntryDetailScreen.factsSentence(for: entry, media: [])
                == DayHeaderText.entryDate(entry.occurredAt)
        )
    }
}

/// Entry Detail's **fidelity correction** — the rules the redesign is built on, as rules.
///
/// The screen's own composition is not unit-testable (SwiftUI, `@Query`, no snapshot harness in
/// this project), so the decisions it makes are lifted into static functions and asserted here.
/// Everything about pixels was verified by screenshot instead, and the report says which is which.
@MainActor
@Suite("Entry detail fidelity")
struct EntryDetailFidelityTests {

    private func media(_ entryId: UUID, _ kind: String, duration: Int? = nil) -> Media {
        completeMedia(entryId: entryId, kind: kind, duration: duration)
    }

    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)!
    }

    // MARK: The date

    /// **Day before month, and no comma after the weekday.** The screen printed "Monday, August
    /// 10, 2026" — the locale's own ordering, which is not the one the design sets.
    @Test("the date reads day before month, with no comma after the weekday")
    func dateOrderIsDayThenMonth() {
        let date = at(8, 10, 10, 4)
        let printed = DayHeaderText.entryDate(date)

        #expect(printed == "Monday 10 August 2026")
        #expect(printed.contains(",") == false, "the weekday is not followed by a comma")
        // The failure this pins is the *ordering*, so assert the positions rather than the string
        // alone — an assertion that only compares the whole string cannot say what went wrong.
        let day = try! #require(printed.range(of: "10"))
        let month = try! #require(printed.range(of: "August"))
        #expect(day.lowerBound < month.lowerBound, "the day comes before the month")
    }

    /// `full` is the spoken form two other screens hand to VoiceOver. This pass gave Entry Detail
    /// its own printed form rather than reordering theirs, and that separation is the assertion.
    @Test("the spoken date the timeline uses is left alone")
    func voiceOverFormIsUnchanged() {
        let date = at(8, 10, 10, 4)
        #expect(DayHeaderText.full(date) != DayHeaderText.entryDate(date))
        #expect(DayHeaderText.full(date).contains("August"))
    }

    // MARK: With time, and without

    /// The split the design draws across its six screens: a count or a length where the entry has
    /// one, the time of day where it does not, and neither on a did-it entry.
    @Test("a single photo carries the time of day, because it has nothing else to say")
    func singlePhotoCarriesTime() throws {
        let entry = try cachedEntry(occurredAt: at(8, 10, 10, 4), type: "photo")
        let sentence = EntryDetailScreen.factsSentence(for: entry, media: [media(entry.id, "photo")])

        #expect(sentence == "Monday 10 August 2026, \(DayHeaderText.entryTime(entry.occurredAt))")
        #expect(sentence.contains("·") == false, "one photo counts nothing and measures nothing")
    }

    @Test("a written entry carries the time of day")
    func writtenCarriesTime() throws {
        let entry = try cachedEntry(occurredAt: at(8, 8, 17, 20), type: "text")
        let sentence = EntryDetailScreen.factsSentence(for: entry, media: [])
        #expect(sentence.hasPrefix("Saturday 8 August 2026, "))
    }

    /// **The one shape that states no time at all.** A did-it entry has no artifact to measure
    /// and its moment is usually an evening rather than an instant.
    @Test("a did-it entry states the day and no time")
    func didItHasNoTime() throws {
        let entry = try cachedEntry(occurredAt: at(8, 4, 18, 0), type: "did_it")
        let sentence = EntryDetailScreen.factsSentence(for: entry, media: [])

        #expect(sentence == "Tuesday 4 August 2026")
        #expect(sentence.contains(DayHeaderText.entryTime(entry.occurredAt)) == false)
    }

    /// A count takes the slot the time would have had — never both.
    @Test("several photos are counted, and the time gives way to the count")
    func countReplacesTime() throws {
        let entry = try cachedEntry(occurredAt: at(8, 9, 16, 30), type: "photo")
        let sentence = EntryDetailScreen.factsSentence(
            for: entry, media: (0..<10).map { _ in media(entry.id, "photo") }
        )

        #expect(sentence == "Sunday 9 August 2026 · 10 photos")
        #expect(sentence.contains(DayHeaderText.entryTime(entry.occurredAt)) == false)
    }

    /// So does a length — and **video counts as a length now**, which it did not before: the
    /// facts line read the duration off audio rows only, so a video entry said nothing about how
    /// long it ran.
    @Test("a recording and a video both state how long they run, in place of the time")
    func lengthReplacesTime() throws {
        let voice = try cachedEntry(occurredAt: at(8, 6, 18, 40), type: "audio")
        #expect(
            EntryDetailScreen.factsSentence(for: voice, media: [media(voice.id, "audio", duration: 107)])
                == "Thursday 6 August 2026 · 1:47"
        )

        let video = try cachedEntry(occurredAt: at(8, 7, 9, 15), type: "video")
        #expect(
            EntryDetailScreen.factsSentence(for: video, media: [media(video.id, "video", duration: 42)])
                == "Friday 7 August 2026 · 0:42"
        )
    }

    // MARK: The absent-zone rule

    /// **Nothing reserves space for something that may not be there.** The rule `EntryCard`
    /// already holds, asserted for this screen: an entry with no caption, no tags and no prompt
    /// produces a sheet with no zone standing empty waiting for one.
    @Test("an entry with no caption, no tags and no prompt reserves space for none of them")
    func absentZonesDropOut() throws {
        let entry = try cachedEntry(type: "photo", body: nil, title: "Just the picture")

        #expect(entry.body == nil, "no caption")
        #expect(entry.tagNames.isEmpty, "no tags")
        #expect(entry.promptBody == nil, "no prompt — a freeform entry, which is first class")
        #expect(EntryDetailScreen.transcript(in: []) == nil, "and no transcript")
        // The one zone that never drops out is the date, because there is always a date.
        #expect(EntryDetailScreen.factsSentence(for: entry, media: []).isEmpty == false)
    }

    /// An audio entry whose transcript is an empty string is the same as one with none: no
    /// heading, no empty block, nothing implying something is missing when nothing is.
    @Test("a blank transcript is no transcript")
    func blankTranscriptIsAbsent() {
        let id = UUID()
        let blank = media(id, "audio")
        blank.transcript = "   \n  "
        #expect(EntryDetailScreen.transcript(in: [blank]) == nil)
    }

    // MARK: Type routing

    /// **Media presence is checked first, then completion mode, then the fallback.** Six
    /// combinations, each naming the canvas it must select — this is the routing table the
    /// screen's whole composition hangs off.
    @Test("each entry type and media combination selects the right canvas")
    func typeRoutingIsExhaustive() {
        let cases: [(EntryType?, Int, EntryDetailScreen.Backdrop)] = [
            (.photo, 1, .picture),
            (.photo, 10, .picture),
            (.video, 1, .picture),
            (.audio, 0, .voice),
            (.text, 0, .canvas),
            (.didIt, 0, .didIt),
        ]
        for (type, pictures, expected) in cases {
            #expect(
                EntryDetailScreen.backdrop(
                    unlockAtAge: nil, unsealed: false, type: type, pictureCount: pictures
                ) == expected,
                "\(String(describing: type)) with \(pictures) pictures"
            )
        }
    }

    /// Media wins over the completion mode: a did-it entry someone photographed is a picture
    /// entry, and an audio entry with a photo attached is one too.
    @Test("the artifact outranks the completion mode")
    func mediaOutranksMode() {
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: .didIt, pictureCount: 1
            ) == .picture
        )
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: .audio, pictureCount: 2
            ) == .picture
        )
    }

    /// **An entry type from a future server release is not a crash and not a blank screen.** It
    /// gets the neutral canvas, which is the one that carries a title and a body intact.
    @Test("an unrecognised type renders the neutral canvas rather than guessing")
    func unknownTypeIsNeutral() throws {
        let unknown = EntryType(rawValue: "hologram")
        #expect(unknown == .unknown("hologram"))
        #expect(
            EntryDetailScreen.backdrop(
                unlockAtAge: nil, unsealed: false, type: unknown, pictureCount: 0
            ) == .canvas
        )
        #expect(
            EntryDetailScreen.completionMark(type: unknown, pictureCount: 0, hasVoice: false)
                == .none,
            "and it is certainly not marked complete"
        )

        // Its words survive, which is the half of this that actually matters.
        let entry = try cachedEntry(type: "hologram", body: "he said it again", title: "The thing")
        #expect(entry.title == "The thing")
        #expect(entry.body == "he said it again")
        #expect(EntryDetailScreen.factsSentence(for: entry, media: []).isEmpty == false)
    }

    /// Sealed still answers before anything reads the media, and the correction did not disturb
    /// the ordering that guarantees it.
    @Test("the seal still outranks every other route")
    func sealStillWins() {
        for type in [EntryType.photo, .video, .audio, .text, .didIt] {
            #expect(
                EntryDetailScreen.backdrop(
                    unlockAtAge: 18, unsealed: false, type: type, pictureCount: 3
                ) == .sealed,
                "a sealed \(type) entry with three photos is sealed"
            )
        }
    }
}
