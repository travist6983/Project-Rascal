import Foundation
import SwiftData
import Testing

@testable import Rascal

/// What a transcript looks like on screen — and, more importantly, what its absence looks like.
///
/// **The absence is the interesting half.** A voice note with no transcript is a complete,
/// legitimate entry: the model may not be installed, the phone may be too old, the child may have
/// said nothing. Every one of those has to render as an ordinary voice entry rather than as one
/// that is missing something — no placeholder, no ghost element, no spinner that lives forever on
/// a card. The rule is "identical to before this feature existed", and these assert it on both
/// surfaces the design system names.
@MainActor
@Suite("Transcript display")
struct TranscriptionDisplayTests {

    // MARK: 10 — No transcript renders exactly as it did yesterday

    @Test("a voice card with no transcript is the card it was before transcription existed")
    func aCardWithNoTranscriptIsUnchanged() throws {
        let context = try inMemoryContext()
        let entry = try cachedEntry(type: "audio", body: nil)
        context.insert(entry)
        let media = completeMedia(entryId: entry.id, kind: "audio", duration: 34)
        context.insert(media)
        try context.save()

        let card = EntryCardModel(entry: entry, media: [media])

        // The voice band is still there, with its duration — that is the design system's spec and
        // it never depended on words.
        let voice = try #require(card.voice)
        #expect(voice.durationSeconds == 34)
        // And the line under it is simply absent. Not an empty string, which would set a zero
        // height Text and open a gap where nothing belongs.
        #expect(voice.openingLine == nil)
        #expect(card.bodyLine == nil)
        #expect(card.searchMatch == nil)
        // Nothing else about the card moved.
        #expect(card.thumbnails.isEmpty)
        #expect(card.overflow == 0)
        #expect(card.typeLabel == "Voice")
        #expect(card.tint == .periwinkle)
    }

    @Test("the parent's own note still leads on a card with no transcript")
    func theParentsNoteIsUntouched() throws {
        let context = try inMemoryContext()
        let entry = try cachedEntry(type: "audio", body: "at the pond, before dinner")
        context.insert(entry)
        let media = completeMedia(entryId: entry.id, kind: "audio", duration: 12)
        context.insert(media)
        try context.save()

        let card = EntryCardModel(entry: entry, media: [media])
        #expect(card.bodyLine?.text == "at the pond, before dinner")
        #expect(card.bodyLine?.isQuote == false)
    }

    @Test("Entry Detail shows no transcript block when there is no transcript")
    func detailShowsNothingWhenThereIsNothing() throws {
        let context = try inMemoryContext()
        let entryId = UUID()
        let media = completeMedia(entryId: entryId, kind: "audio", duration: 34)
        context.insert(media)
        try context.save()

        // No heading, no empty block, nothing to say the archive is waiting on something.
        #expect(EntryDetailScreen.transcript(in: [media]) == nil)
    }

    @Test("Entry Detail treats a whitespace-only transcript as no transcript")
    func detailTreatsBlankAsAbsent() throws {
        let context = try inMemoryContext()
        let media = completeMedia(entryId: UUID(), kind: "audio", transcript: "   \n ")
        context.insert(media)
        try context.save()

        #expect(EntryDetailScreen.transcript(in: [media]) == nil)
    }

    @Test("a photo entry never grows a transcript block, whatever else is on it")
    func photosHaveNoTranscriptBlock() throws {
        let context = try inMemoryContext()
        let media = completeMedia(entryId: UUID(), kind: "photo")
        context.insert(media)
        try context.save()

        #expect(EntryDetailScreen.transcript(in: [media]) == nil)
    }

    // MARK: What a transcript does add

    @Test("Entry Detail sets the transcript as readable words once there are some")
    func detailShowsTheTranscript() throws {
        let context = try inMemoryContext()
        let media = completeMedia(
            entryId: UUID(), kind: "audio",
            transcript: "and then the brachiosaurus ate the whole entire tree"
        )
        context.insert(media)
        try context.save()

        #expect(EntryDetailScreen.transcript(in: [media])
            == "and then the brachiosaurus ate the whole entire tree")
    }

    @Test("the card takes the first line of the transcript when the parent wrote nothing")
    func theCardQuotesTheChild() throws {
        let context = try inMemoryContext()
        let entry = try cachedEntry(type: "audio", body: nil)
        context.insert(entry)
        let media = completeMedia(
            entryId: entry.id, kind: "audio", duration: 90,
            transcript: "we saw a duck\nand it had babies"
        )
        context.insert(media)
        try context.save()

        let card = EntryCardModel(entry: entry, media: [media])
        #expect(card.voice?.openingLine == "we saw a duck")
        // Italic, because the words are the child's rather than the parent's summary of them.
        #expect(card.bodyLine?.text == "we saw a duck")
        #expect(card.bodyLine?.isQuote == true)
    }

    @Test("a deleted voice note contributes no transcript to the card that outlived it")
    func deletedMediaContributesNothing() throws {
        let context = try inMemoryContext()
        let entry = try cachedEntry(type: "audio", body: nil)
        context.insert(entry)
        let media = completeMedia(entryId: entry.id, kind: "audio", transcript: "gone now")
        media.deletedAt = Date()
        context.insert(media)
        try context.save()

        let card = EntryCardModel(entry: entry, media: [media], searchQuery: "gone")
        #expect(card.voice == nil)
        #expect(card.searchMatch == nil)
    }
}
