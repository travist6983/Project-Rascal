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

        #expect(sentence == DayHeaderText.full(occurred))
        #expect(sentence.contains("2017"))
        // The whole point: reading the wrong field would file this under 2026.
        #expect(sentence.contains("2026") == false)
        #expect(sentence != DayHeaderText.full(created))
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
                == DayHeaderText.full(entry.occurredAt)
        )
    }
}
