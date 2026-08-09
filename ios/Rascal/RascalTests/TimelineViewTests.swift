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

    @Test("nine photos become three tiles and a +6")
    func overflowCounts() throws {
        let entry = try cachedEntry(type: "photo", mediaCount: 9)
        let media = (0..<9).map { _ in completeMedia(entryId: entry.id) }
        let card = EntryCardModel(entry: entry, media: media)

        #expect(card.thumbnails.count == EntryCardModel.maxTiles - 1)
        #expect(card.overflow == 6)
        #expect(card.thumbnails.count + card.overflow == 9)
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
