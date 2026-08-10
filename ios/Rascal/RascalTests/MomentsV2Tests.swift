import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Moments v2 — the states the screen is actually in.
///
/// **The fallback is the ordinary case here, not the edge one.** The archive is days old, so
/// "1 year ago" is empty on nearly every date and will be for a long time; what a parent sees
/// most mornings is the warm redirect. It is therefore tested first and tested hardest, and the
/// populated carousel is the state that has to prove it differs from it.
@MainActor
@Suite("Moments v2")
struct MomentsV2Tests {

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

    private func day(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter.date(from: iso)!
    }

    private func loaded(
        _ body: String, child: UUID = UUID(), date: String? = nil
    ) async throws -> (MomentsModel, StubPerformer) {
        let context = try makeContext()
        let performer = StubPerformer()
        let data = Data(body.utf8)
        performer.on("/moments") { _ in (data, 200) }
        let model = MomentsModel(
            childId: child, api: client(performer), context: context, date: date
        )
        await model.start()
        return (model, performer)
    }

    // MARK: The redirect

    @Test("the warm redirect is a section like any other, and says which day it stood in for")
    func fallbackIsAWarmRedirect() async throws {
        let child = UUID()
        let entry = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2023-07-22 14:00"),
            type: "text", body: "he called it a hangaburger"
        )
        let (model, _) = try await loaded(
            #"{"date":"2026-08-11","fallback":"random","groups":[],"entries":[\#(entry)]}"#,
            child: child
        )

        let section = try #require(model.sections.first)
        #expect(model.isFallback)
        #expect(model.date == "2026-08-11")
        #expect(section.isFallback)
        #expect(section.title == "From the archive")
        #expect(section.cards.count == 1)
        // The header prints neither of these on a redirect: five random memories come from five
        // days and five ages, and one of each over all of them would be wrong four times.
        #expect(section.occurredOn == nil)
        #expect(section.ageMonths == nil)
    }

    @Test("a hit and a redirect are not the same screen")
    func fallbackIsDistinguishableFromAHit() async throws {
        let child = UUID()
        let hitEntry = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2025-08-11 09:00"),
            type: "text", body: "told the whole shop his name", ageMonths: 38
        )
        let (hit, _) = try await loaded(
            #"{"date":"2026-08-11","fallback":null,"groups":[{"years_ago":1,"entries":[\#(hitEntry)]}],"entries":[]}"#,
            child: child
        )

        let missEntry = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2023-07-22 14:00"), type: "text"
        )
        let (miss, _) = try await loaded(
            #"{"date":"2026-08-11","fallback":"random","groups":[],"entries":[\#(missEntry)]}"#,
            child: UUID()
        )

        let hitSection = try #require(hit.sections.first)
        let missSection = try #require(miss.sections.first)

        // Four things differ, and every one of them is on screen: the eyebrow on the throwback
        // card and the section heading, the date beside it, the age chip, and the italic note.
        #expect(hitSection.title != missSection.title)
        #expect(hitSection.isFallback == false && missSection.isFallback)
        #expect(hitSection.occurredOn != nil && missSection.occurredOn == nil)
        #expect(hitSection.ageMonths != nil && missSection.ageMonths == nil)
    }

    @Test("a date with nothing on it takes the redirect, and asks the server for that date")
    func honoursTheDateParameter() async throws {
        let child = UUID()
        let entry = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2022-02-02 10:00"), type: "text"
        )
        let (model, performer) = try await loaded(
            #"{"date":"2026-08-11","fallback":"random","groups":[],"entries":[\#(entry)]}"#,
            child: child, date: "2026-08-11"
        )

        let asked = performer.requests.compactMap(\.url).first { $0.path().contains("moments") }
        let url = try #require(asked)
        let query = try #require(url.query())
        #expect(query.contains("date=2026-08-11"), "the day named by the caller reaches the server")
        #expect(model.isFallback, "nothing on that date, so the server stood the archive in")
        #expect(model.sections.count == 1)
    }

    // MARK: Nothing at all

    @Test("an empty archive draws no carousel at all, rather than one with no height")
    func emptyArchiveHasNoCarousel() async throws {
        let (model, _) = try await loaded(
            #"{"date":"2026-08-11","fallback":"random","groups":[],"entries":[]}"#
        )

        #expect(model.hasLoaded)
        // `MomentsScreen` draws the carousel only from a non-empty `sections`, so an empty
        // archive takes the invitation branch instead of laying out a rail with nothing in it.
        #expect(model.sections.isEmpty)
        #expect(model.notice == nil, "nothing failed, so nothing is reported as a failure")
        #expect(model.isFallback, "the server did answer — it just had nothing to answer with")
        #expect(model.failed == false, "and because it answered, the invitation is the right screen")
    }

    /// A parent holding 755 entries opens Moments on a train. The request fails, `sections` is
    /// empty — and the invitation must not appear, because "nothing to look back on yet" would be
    /// a false statement about their archive caused by a tunnel.
    @Test("a load that failed is not an empty archive, and never says it is")
    func failureIsNotAnEmptyArchive() async throws {
        let context = try makeContext()
        let performer = StubPerformer()
        let boom = Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8)
        performer.on("/moments") { _ in (boom, 500) }

        let model = MomentsModel(childId: UUID(), api: client(performer), context: context)
        await model.start()

        #expect(model.hasLoaded)
        #expect(model.sections.isEmpty)
        #expect(model.failed, "this is the flag the screen branches on")
        #expect(model.notice != nil, "and the quiet note says what actually happened")

        // The distinction, stated as the screen states it: same empty `sections`, opposite answer.
        let (answered, _) = try await loaded(
            #"{"date":"2026-08-11","fallback":"random","groups":[],"entries":[]}"#
        )
        #expect(answered.sections.isEmpty && answered.failed == false)
        #expect(model.sections.isEmpty && model.failed)
    }

    @Test("a recovered load stops reporting a failure it is no longer having")
    func recoveryClearsTheFailure() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        let entry = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2025-08-09 10:00"), type: "text"
        )
        let good = Data(
            #"{"date":"2026-08-09","fallback":null,"groups":[{"years_ago":1,"entries":[\#(entry)]}],"entries":[]}"#.utf8
        )
        let boom = Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8)
        // The two loads below are awaited one after the other, so this is read and written on one
        // task at a time — no interleaving to protect against beyond `Mutex`'s own accessor.
        let failFirst = Mutex(true)
        performer.on("/moments") { _ in
            if failFirst.value {
                failFirst.value = false
                return (boom, 500)
            }
            return (good, 200)
        }

        let model = MomentsModel(childId: child, api: client(performer), context: context)
        await model.start()
        #expect(model.failed)

        await model.load()
        #expect(model.failed == false)
        #expect(model.notice == nil)
        #expect(model.sections.count == 1)
    }

    @Test("the closing line spells its number in the language the rest of the sentence is in")
    func spelledCountIsEnglish() {
        // The sentence around it is hard-coded English. Following the device locale would produce
        // "Seis years of 9 August."
        #expect(CountText.spelled(6) == "Six")
        #expect(CountText.spelled(1) == "One")
        #expect(CountText.spelled(12) == "Twelve")
    }

    // MARK: Grouping

    @Test("one year back is one section, headed with the day and the age")
    func singleYearGrouping() async throws {
        let child = UUID()
        let entry = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2025-08-09 18:30"),
            type: "text", body: "told the whole shop his name", ageMonths: 38
        )
        let (model, _) = try await loaded(
            #"{"date":"2026-08-09","fallback":null,"groups":[{"years_ago":1,"entries":[\#(entry)]}],"entries":[]}"#,
            child: child
        )

        #expect(model.sections.count == 1)
        let section = try #require(model.sections.first)
        #expect(section.title == "1 year ago", "singular, and nothing counts down")
        #expect(section.yearsAgo == 1)
        #expect(section.ageMonths == 38)
        #expect(section.occurredOn == day("2025-08-09 18:30"))
    }

    @Test("several years back are ordered nearest first, the way the server sent them")
    func multiYearGroupingIsOrdered() async throws {
        let child = UUID()
        let one = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2025-08-09 10:00"), type: "text"
        )
        let three = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2023-08-09 10:00"), type: "text"
        )
        let six = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2020-08-09 10:00"), type: "text"
        )
        let (model, _) = try await loaded(
            """
            {"date":"2026-08-09","fallback":null,
             "groups":[{"years_ago":1,"entries":[\(one)]},
                       {"years_ago":3,"entries":[\(three)]},
                       {"years_ago":6,"entries":[\(six)]}],
             "entries":[]}
            """,
            child: child
        )

        #expect(model.sections.map(\.title) == ["1 year ago", "3 years ago", "6 years ago"])
        #expect(model.sections.compactMap(\.yearsAgo) == [1, 3, 6])
    }

    // MARK: Ordering

    @Test("memories sort by when they happened, never by when they were uploaded")
    func ordersByOccurredAtRatherThanCreatedAt() async throws {
        let child = UUID()
        // A camera-roll backfill: the *older* memory was imported last night, so ordering by
        // `created_at` would put it first and date four years of archive to the evening someone
        // plugged their phone in.
        let earlier = entryJSON(
            id: UUID(), childId: child,
            occurredAt: day("2025-08-09 08:00"), createdAt: day("2026-08-08 23:00"),
            type: "text", body: "breakfast, first day"
        )
        let later = entryJSON(
            id: UUID(), childId: child,
            occurredAt: day("2025-08-09 20:00"), createdAt: day("2025-08-09 20:05"),
            type: "text", body: "bathtime, same day"
        )
        let (model, _) = try await loaded(
            #"{"date":"2026-08-09","fallback":null,"groups":[{"years_ago":1,"entries":[\#(earlier),\#(later)]}],"entries":[]}"#,
            child: child
        )

        let cards = try #require(model.sections.first?.cards)
        #expect(cards.count == 2)
        #expect(
            cards.map(\.occurredAt) == [day("2025-08-09 20:00"), day("2025-08-09 08:00")],
            "newest by occurrence leads; created_at ordering would have reversed these"
        )
        #expect(cards.first?.preview == "bathtime, same day")
    }

    // MARK: The seal

    /// The highest-consequence defect this screen could ship.
    ///
    /// A sealed letter is a letter written *to* him, not readable until he is old enough. If
    /// Moments surfaced one with its words in the card or its photo behind a throwback scrim,
    /// the seal would be decorative — and it would be broken silently, on a screen nobody
    /// navigated to deliberately.
    @Test("a sealed letter surfaced in Moments stays sealed, words and picture both")
    func sealedMemoryStaysSealed() async throws {
        let child = UUID()
        let sealed = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2025-08-09 21:00"),
            type: "text", body: "the things I could not say to you out loud yet",
            title: "A letter", ageMonths: 38, unlockAtAge: 18,
            tags: ["Letter"], media: [mediaJSON()]
        )
        let (model, _) = try await loaded(
            #"{"date":"2026-08-09","fallback":"random","groups":[],"entries":[\#(sealed)]}"#,
            child: child
        )

        let section = try #require(model.sections.first)
        let card = try #require(section.cards.first)

        #expect(card.isSealed, "the sealed skin is chosen from this and nothing else")
        #expect(card.unlockAtAge == 18)
        #expect(card.preview == nil, "the body is never read, so there is nothing to leak or blur")
        #expect(card.bodyLine == nil, "and nothing reaches the card's body line either")
        // The entry *has* a photo. It must not become a throwback cover: a sealed letter behind
        // a scrim in the carousel would show the picture the seal exists to hold back.
        #expect(card.thumbnails.isEmpty, "a sealed entry contributes no tiles")
        #expect(section.cover == nil, "and therefore no cover photo for the throwback card")
        #expect(card.tags.isEmpty, "even the tags stay in")
    }

    @Test("the sealed card still says the one thing that is not sealed — when it opens")
    func sealedMemoryStillSaysWhenItOpens() async throws {
        let child = UUID()
        let sealed = entryJSON(
            id: UUID(), childId: child, occurredAt: day("2025-08-09 21:00"),
            type: "text", body: "for later", title: "A letter", unlockAtAge: 13
        )
        let (model, _) = try await loaded(
            #"{"date":"2026-08-09","fallback":"random","groups":[],"entries":[\#(sealed)]}"#,
            child: child
        )

        let card = try #require(model.sections.first?.cards.first)
        #expect(card.unlockAtAge == 13)
        #expect(card.title == "A letter")
    }

    // MARK: Copy

    /// **Word order is the device's, the day is the server's.**
    ///
    /// The design file writes this line as "Sunday 9 August"; on an `en_US` phone the app renders
    /// "Sunday, August 9", because every other date in this app — the timeline's day headers, the
    /// date on Entry Detail — has been locale-driven since Phase 4. Pinning Moments alone to the
    /// design's British order would print "Sunday 9 August" two lines above a section header
    /// reading "Aug 9, 2026" on the same screen. So the order is deliberately not asserted here.
    ///
    /// What *is* asserted is the part that would be a defect: the day named is the day the server
    /// computed in the child's timezone. `CalendarDay` reads noon UTC and formats back in UTC, so
    /// a phone at UTC+14 — where that instant is already tomorrow morning — still prints the 9th.
    @Test("a calendar day the server named renders as that day, whatever the phone is set to")
    func calendarDayIsTheServersDay() throws {
        let rendered = try #require(CalendarDay.weekdayDayMonth("2026-08-09"))
        #expect(rendered.contains("9"), "the server said the ninth")
        #expect(rendered.contains("August"))
        #expect(rendered.contains("Sunday"), "and the ninth of August 2026 was a Sunday")
        #expect(rendered.contains("10") == false, "never tomorrow, on any phone")

        let midSentence = try #require(CalendarDay.dayMonth("2026-08-11"))
        #expect(midSentence.contains("11"))
        #expect(midSentence.contains("August"))

        #expect(CalendarDay.dayMonth("nonsense") == nil, "a day it cannot read is not guessed at")
    }
}
