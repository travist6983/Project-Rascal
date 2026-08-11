import Foundation
import Testing

@testable import Rascal

/// What the timeline draws, and the rules it must not break while drawing it.

// MARK: - Grouping

@Suite("Timeline grouping")
struct TimelineGroupingTests {

    private struct Row: Equatable {
        let label: String
        let occurredAt: Date
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(_ iso: String, in zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: zone)!
        return formatter.date(from: iso)!
    }

    private func group(_ rows: [Row], zone: String = "America/New_York")
        -> [TimelineGrouping.Day<Row>]
    {
        TimelineGrouping.days(rows, calendar: calendar(zone), occurredAt: \.occurredAt)
    }

    @Test("entries on the same day land in one group, newest day first")
    func groupsByDay() {
        let groups = group([
            Row(label: "evening", occurredAt: date("2026-08-08 21:00", in: "America/New_York")),
            Row(label: "morning", occurredAt: date("2026-08-08 07:30", in: "America/New_York")),
            Row(label: "yesterday", occurredAt: date("2026-08-07 12:00", in: "America/New_York")),
        ])

        #expect(groups.count == 2)
        #expect(groups[0].items.map(\.label) == ["evening", "morning"])
        #expect(groups[1].items.map(\.label) == ["yesterday"])
    }

    @Test("a spring-forward day is still one day")
    func handlesSpringForward() {
        // 2026-03-08 in New York is 23 hours long. Anything dividing by 86,400 puts the
        // evening on the ninth.
        let groups = group([
            Row(label: "late", occurredAt: date("2026-03-08 23:30", in: "America/New_York")),
            Row(label: "early", occurredAt: date("2026-03-08 01:30", in: "America/New_York")),
        ])

        #expect(groups.count == 1, "one calendar day, however many hours it happened to have")
        #expect(groups[0].items.count == 2)
    }

    @Test("a fall-back day is still one day")
    func handlesFallBack() {
        // 2026-11-01 in New York is 25 hours long and 01:30 happens twice.
        let groups = group([
            Row(label: "later", occurredAt: date("2026-11-01 23:00", in: "America/New_York")),
            Row(label: "earlier", occurredAt: date("2026-11-01 00:30", in: "America/New_York")),
        ])

        #expect(groups.count == 1)
    }

    @Test("the year divider marks the first day of the older year, and never the first group")
    func marksYearBoundaries() {
        let groups = group([
            Row(label: "new year", occurredAt: date("2026-01-01 10:00", in: "America/New_York")),
            Row(label: "new year eve", occurredAt: date("2025-12-31 22:00", in: "America/New_York")),
            Row(label: "christmas", occurredAt: date("2025-12-25 09:00", in: "America/New_York")),
            Row(label: "long ago", occurredAt: date("2024-12-31 09:00", in: "America/New_York")),
        ])

        #expect(groups.count == 4)
        #expect(groups[0].yearDivider == nil, "nothing precedes the first group")
        #expect(groups[1].yearDivider == 2025)
        #expect(groups[2].yearDivider == nil, "same year as the day above it")
        #expect(groups[3].yearDivider == 2024)
    }

    @Test("a midnight-boundary entry groups by the local day, not by UTC")
    func groupsInLocalTime() {
        // 2026-08-09 00:30 UTC is 2026-08-08 20:30 in New York. The parent's evening, not the
        // next morning.
        let groups = group([
            Row(label: "tonight", occurredAt: date("2026-08-08 20:30", in: "America/New_York")),
            Row(label: "this morning", occurredAt: date("2026-08-08 09:00", in: "America/New_York")),
        ])
        #expect(groups.count == 1)
    }

    @Test("nothing in, nothing out")
    func handlesEmpty() {
        #expect(group([]).isEmpty)
    }
}

// MARK: - The card

@MainActor
@Suite("Entry card")
struct EntryCardModelTests {

    @Test("a written entry has no thumbnail slot at all")
    func textOnlyHasNoMedia() throws {
        // Half the mission library produces no artifact. A written entry is complete, and it
        // must not render an empty frame where a picture would go.
        let entry = try cachedEntry(type: "text", body: "He called it a hangaburger again.")
        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.thumbnails.isEmpty)
        #expect(card.overflow == 0)
        #expect(card.hasMedia == false)
        #expect(card.typeLabel == "Written")
        #expect(card.preview == "He called it a hangaburger again.")
    }

    @Test("a did-it entry keeps its type and its tint, note or no note")
    func didItStaysDidIt() throws {
        let bare = try cachedEntry(type: "did_it", body: nil)
        let noted = try cachedEntry(type: "did_it", body: "ten minutes on the floor")

        #expect(EntryCardModel(entry: bare, media: []).isDidIt)
        #expect(EntryCardModel(entry: noted, media: []).isDidIt)
        #expect(EntryCardModel(entry: noted, media: []).typeLabel == "Did it")
        #expect(EntryCardModel(entry: bare, media: []).hasMedia == false)
    }

    @Test("one photo is one tile and no overflow")
    func singlePhoto() throws {
        let entry = try cachedEntry(type: "photo", mediaCount: 1)
        let card = EntryCardModel(entry: entry, media: [completeMedia(entryId: entry.id)])

        #expect(card.thumbnails.count == 1)
        #expect(card.overflow == 0)
    }

    @Test("nine photos fill the 2×2 and print +5 on the last tile")
    func overflowCounts() throws {
        // v3 overlays the count rather than spending a tile on it, which is what keeps a
        // nine-photo card the same height as a four-photo one.
        let entry = try cachedEntry(type: "photo", mediaCount: 9)
        let media = (0..<9).map { _ in completeMedia(entryId: entry.id) }
        let card = EntryCardModel(entry: entry, media: media)

        #expect(card.thumbnails.count == EntryCardModel.maxTiles)
        #expect(card.overflow == 5)
        #expect(card.thumbnails.count + card.overflow == 9)
    }

    @Test("exactly four photos is a full mosaic and no count")
    func fourPhotosHaveNoOverflow() throws {
        let entry = try cachedEntry(type: "photo", mediaCount: 4)
        let media = (0..<4).map { _ in completeMedia(entryId: entry.id) }
        let card = EntryCardModel(entry: entry, media: media)

        #expect(card.thumbnails.count == 4)
        #expect(card.overflow == 0, "a +0 badge over the fourth picture would be nonsense")
    }

    @Test("a photo still uploading elsewhere is counted even though it cannot be drawn")
    func countsServerMediaWithNoLocalRow() throws {
        // The server says four; this phone has cached two, because the other two are still
        // uploading from another device. Claiming two would be the wrong way to be wrong.
        let entry = try cachedEntry(type: "photo", mediaCount: 4)
        let card = EntryCardModel(entry: entry, media: [
            completeMedia(entryId: entry.id), completeMedia(entryId: entry.id),
        ])

        #expect(card.thumbnails.count == 2)
        #expect(card.overflow == 2)
    }

    @Test("a voice note is never a picture tile")
    func audioStaysOutOfTheMosaic() throws {
        // A device caught this: the mosaic drew the recording as a 242pt periwinkle rectangle
        // and the voice band drew the same recording again underneath it.
        let entry = try cachedEntry(type: "audio", body: nil, mediaCount: 1)
        let audio = completeMedia(entryId: entry.id, kind: "audio", duration: 107)
        let card = EntryCardModel(entry: entry, media: [audio])

        #expect(card.thumbnails.isEmpty)
        #expect(card.overflow == 0, "one audio row is not one uncounted picture")
        #expect(card.hasMedia == false)
        #expect(card.voice != nil, "it still gets its band")
    }

    @Test("photos are counted and drawn around an audio row on the same entry")
    func picturesSurviveAnAudioSibling() throws {
        // An entry can hold both — a recording and the photos taken beside it. The mosaic gets
        // the pictures and only the pictures, and the count stays honest.
        let entry = try cachedEntry(type: "photo", mediaCount: 3)
        let media = [
            completeMedia(entryId: entry.id),
            completeMedia(entryId: entry.id),
            completeMedia(entryId: entry.id, kind: "audio", duration: 30),
        ]
        let card = EntryCardModel(entry: entry, media: media)

        #expect(card.thumbnails.count == 2)
        #expect(card.overflow == 0, "the third row is the audio, not a third picture")
        #expect(card.voice != nil)
    }

    @Test("a voice entry carries its duration and the first line of the transcript")
    func voiceChip() throws {
        let entry = try cachedEntry(type: "audio", body: nil)
        let audio = completeMedia(
            entryId: entry.id, kind: "audio", duration: 64,
            transcript: "we went to the pond\nand fed the ducks"
        )
        let card = EntryCardModel(entry: entry, media: [audio])

        #expect(card.voice?.durationSeconds == 64)
        #expect(card.voice?.openingLine == "we went to the pond")
        #expect(card.typeLabel == "Voice")
    }

    @Test("a sealed letter shows its title and keeps everything else sealed")
    func sealedShowsNothing() throws {
        let entry = try cachedEntry(
            type: "text", body: "Dear you, on the day you turn eighteen",
            title: "A letter", unlockAtAge: 18, tags: ["letters"], mediaCount: 2
        )
        let card = EntryCardModel(entry: entry, media: [completeMedia(entryId: entry.id)])

        #expect(card.isSealed)
        #expect(card.unlockAtAge == 18)
        #expect(card.title == "A letter")
        #expect(card.preview == nil, "rendering the first two lines would make the seal decorative")
        #expect(card.thumbnails.isEmpty)
        #expect(card.overflow == 0)
        #expect(card.tags.isEmpty)
    }

    @Test("an entry not yet pushed says so quietly and is otherwise a normal card")
    func awaitingSync() throws {
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "written on a train")
        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.isAwaitingSync)
        #expect(card.preview == "written on a train")
        // An entry saved locally but not yet synced is never presented as an error or a loss.
        #expect(card.type == nil, "the server has not derived a type yet, and this does not guess")
    }

    @Test("a body of blank lines is no preview rather than an empty one")
    func collapsesWhitespace() {
        #expect(EntryCardModel.preview(of: "\n\n   \n") == nil)
        #expect(EntryCardModel.preview(of: "  first  \n\nsecond\nthird") == "first second")
        #expect(EntryCardModel.preview(of: nil) == nil)
    }

    @Test("deleted media is not drawn on a card that survived it")
    func ignoresDeletedMedia() throws {
        let entry = try cachedEntry(type: "photo", mediaCount: 0)
        let gone = completeMedia(entryId: entry.id)
        gone.deletedAt = Date()

        #expect(EntryCardModel(entry: entry, media: [gone]).thumbnails.isEmpty)
    }
}

// MARK: - The prompt the card is built around

@MainActor
@Suite("Entry card prompt")
struct EntryCardPromptTests {

    @Test("the quote is the prompt the server recorded against this entry")
    func promptBodyIsTheSource() throws {
        let entry = try cachedEntry(prompt: "Photograph the mess. Don't clean it up first.")
        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.prompt == "Photograph the mess. Don't clean it up first.")
    }

    /// **Replaces `fallsBackToAssignment`, whose premise the server has since falsified.**
    ///
    /// That test asserted the local `Assignment` lookup, on the stated grounds that
    /// "`GET /entries` does not carry `prompt`". It does now — verified in phase 19 against a
    /// running server, where eleven of eleven rows with an `assignment_id` came back with a
    /// non-null `prompt_body`. The fallback was also resolving nothing in practice, because
    /// `Assignment` rows are written only by `SyncEngine` from a `/sync` response and sync pull
    /// ships behind `syncPullEnabled`, which is off.
    ///
    /// So this asserts the case the fallback used to cover, with the fallback gone: an entry that
    /// completed an assignment, **no cached `Assignment` anywhere**, and the quote still renders.
    @Test("a list row quotes its prompt with no cached assignment to look up")
    func listRowQuotesWithoutAnAssignmentLookup() throws {
        let entry = try cachedEntry(
            assignmentId: UUID(),
            prompt: "Get on the floor for ten minutes. That's the whole mission."
        )
        let card = EntryCardModel(entry: entry, media: [])

        #expect(entry.assignmentId != nil, "this row completed an assignment")
        #expect(card.prompt == "Get on the floor for ten minutes. That's the whole mission.")
    }

    /// The other half of the same deletion: with `prompt_body` genuinely absent there is nothing
    /// to show, and the card must leave the space out rather than reserve it for a lookup that
    /// no longer happens.
    @Test("a row the server sent no prompt for quotes nothing")
    func listRowWithoutPromptQuotesNothing() throws {
        let entry = try cachedEntry(assignmentId: UUID())

        #expect(entry.promptBody == nil)
        #expect(EntryCardModel(entry: entry, media: []).prompt == nil)
    }

    @Test("a freeform entry has no prompt and the zone drops out")
    func freeformHasNoPrompt() throws {
        // Nothing was asked, so there is nothing to quote. The card must not reserve the space.
        let entry = try cachedEntry(body: "Just a thing I wanted to keep.")
        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.prompt == nil)
    }

    @Test("a sealed letter still shows the prompt it answered")
    func sealedKeepsItsPrompt() throws {
        // The seal is on the letter, not on the question. Hiding the prompt too would leave a
        // card that says nothing at all about why it exists.
        let entry = try cachedEntry(
            body: "Dear you, on the day you turn eighteen",
            title: "A letter", unlockAtAge: 18,
            prompt: "Write him something about money you wish you'd been told at nineteen."
        )
        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.isSealed)
        #expect(card.prompt?.hasPrefix("Write him something about money") == true)
        #expect(card.preview == nil, "the letter itself stays sealed")
    }
}

// MARK: - What the card sets as its body

@MainActor
@Suite("Entry card body")
struct EntryCardBodyTests {

    @Test("a written entry gets a third line, because the writing is the artifact")
    func writtenGetsThreeLines() throws {
        // Escaped in the source, so the fixture emits valid JSON and the decoder produces the
        // real newlines. A bare "\n" here is an unescaped control character in the body.
        let lines = #"one\ntwo\nthree\nfour"#
        let written = try cachedEntry(type: "text", body: lines)
        let photo = try cachedEntry(type: "photo", body: lines)

        #expect(written.type == .text)
        #expect(EntryCardModel(entry: written, media: []).bodyLineLimit == 3)
        #expect(EntryCardModel(entry: written, media: []).preview == "one two three")
        #expect(EntryCardModel(entry: photo, media: []).bodyLineLimit == 2)
        #expect(EntryCardModel(entry: photo, media: []).preview == "one two")
    }

    @Test("the parent's words are the body when there are any")
    func parentWordsWin() throws {
        let entry = try cachedEntry(type: "audio", body: "He talked for two minutes straight.")
        let audio = completeMedia(
            entryId: entry.id, kind: "audio", duration: 107, transcript: "and then the dinosaur"
        )
        let line = EntryCardModel(entry: entry, media: [audio]).bodyLine

        #expect(line?.text == "He talked for two minutes straight.")
        #expect(line?.isQuote == false, "the parent's summary is set upright")
    }

    @Test("a voice note with no note of its own quotes the transcript instead")
    func transcriptFillsIn() throws {
        // Recording the child and writing nothing is the common way to make a voice entry. His
        // words are then the only words the card has, and they are somebody else's — italic.
        let entry = try cachedEntry(type: "audio", body: nil)
        let audio = completeMedia(
            entryId: entry.id, kind: "audio", duration: 107,
            transcript: "and then the dinosaur he goed to the bus stop"
        )
        let line = EntryCardModel(entry: entry, media: [audio]).bodyLine

        #expect(line?.text == "and then the dinosaur he goed to the bus stop")
        #expect(line?.isQuote == true)
    }

    @Test("a did-it entry with no note has no body line at all")
    func bareDidItHasNoBody() throws {
        // Complete, legitimate, and it renders as a prompt and a title. Not as a blank row and
        // not as a card with an empty paragraph holding space open.
        let entry = try cachedEntry(type: "did_it", body: nil)
        let card = EntryCardModel(entry: entry, media: [])

        #expect(card.bodyLine == nil)
        #expect(card.hasMedia == false)
        #expect(card.isDidIt)
    }

    @Test("colour follows meaning, not the brand")
    func tintsByKind() throws {
        // Terracotta is photo and video, periwinkle is voice and writing, sage is did-it.
        // A question card tinted terracotta because terracotta is the brand colour is a defect.
        #expect(try EntryCardModel(entry: cachedEntry(type: "photo"), media: []).tint == .terracotta)
        #expect(try EntryCardModel(entry: cachedEntry(type: "video"), media: []).tint == .terracotta)
        #expect(try EntryCardModel(entry: cachedEntry(type: "audio"), media: []).tint == .periwinkle)
        #expect(try EntryCardModel(entry: cachedEntry(type: "text"), media: []).tint == .periwinkle)
        #expect(try EntryCardModel(entry: cachedEntry(type: "did_it"), media: []).tint == .sage)
    }
}

// MARK: - Words

@Suite("Formatting")
struct FormattingTests {

    @Test("age reads as a person would say it")
    func ageText() {
        #expect(AgeText.chip(0) == "newborn")
        #expect(AgeText.chip(11) == "11 mo")
        #expect(AgeText.chip(24) == "2y")
        #expect(AgeText.chip(62) == "5y 2m")
        #expect(AgeText.greeting(1) == "1 month old")
        #expect(AgeText.greeting(24) == "2 years old")
        #expect(AgeText.spoken(62) == "5 years 2 months old")
        #expect(AgeText.spoken(1) == "1 month old")
        // The long form sits opposite the words "Age at the time", so it never says "old" —
        // that row would otherwise state age twice.
        #expect(AgeText.long(62) == "5 years, 2 months")
        #expect(AgeText.long(24) == "2 years")
        #expect(AgeText.long(11) == "11 months")
        #expect(AgeText.long(1) == "1 month")
        #expect(AgeText.long(0) == "Newborn")
        #expect(!AgeText.long(62).contains("old"))
    }

    @Test("durations read as a clock, and as words for VoiceOver")
    func durationText() {
        #expect(DurationText.clock(64) == "1:04")
        #expect(DurationText.clock(9) == "0:09")
        #expect(DurationText.clock(-5) == "0:00")
        #expect(DurationText.spoken(64) == "1 minute 4 seconds")
        #expect(DurationText.spoken(120) == "2 minutes")
        #expect(DurationText.spoken(1) == "1 second")
    }
}
