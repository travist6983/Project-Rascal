import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Five hundred entries — about eight months of an archive that gets used twice a day.
///
/// A scroll is only as smooth as what happens on the main actor between frames, and on this
/// screen that is three things: folding a page into SwiftData, flattening rows into card models,
/// and grouping them by day. None of them may be O(n²), and none may reach back into the store
/// per row — the defect this guards against is a card that fetches its own media, which looks
/// fine at twenty entries and janks at five hundred.
///
/// The budgets are deliberately loose. They are not a benchmark; they are a tripwire for an
/// accidental N+1, which shows up as seconds rather than as a few extra milliseconds.
@MainActor
@Suite("Timeline at scale")
struct TimelineScaleTests {

    private static let count = 500

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Two entries a day for 250 days, starting in August 2024 so the list crosses a new year
    /// and exercises the divider. Every third entry carries a photo, roughly matching the shape
    /// of a real archive.
    private func fixture(childId: UUID) throws -> [EntryResponse] {
        let start = Date(timeIntervalSince1970: 1_722_470_400)  // 2024-08-01T00:00:00Z
        return try (0..<Self.count).map { index in
            let day = Double(index / 2) * 86_400
            let hour = Double(index % 2) * 6 * 3_600
            let media = index % 3 == 0 ? [mediaJSON()] : []
            return try decodeEntry(entryJSON(
                id: UUID(),
                childId: childId,
                occurredAt: start.addingTimeInterval(day + hour),
                type: media.isEmpty ? "text" : "photo",
                body: "day \(index) of an archive that gets used",
                ageMonths: 40 + index / 30,
                media: media
            ))
        }
    }

    @Test("five hundred entries fold into the cache without a per-row round trip")
    func upsertsAPageOfPages() throws {
        let context = try makeContext()
        let responses = try fixture(childId: UUID())

        let began = ContinuousClock.now
        // Ten pages of fifty, which is how they actually arrive.
        for page in stride(from: 0, to: responses.count, by: TimelineModel.pageSize) {
            EntryCache.upsert(
                Array(responses[page..<min(page + TimelineModel.pageSize, responses.count)]),
                into: context
            )
        }
        let elapsed = ContinuousClock.now - began

        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == Self.count)
        #expect(elapsed < .seconds(10), "\(elapsed) to cache \(Self.count) entries")
    }

    @Test("re-fetching a page it already has creates nothing and changes nothing")
    func reconcileIsIdempotent() throws {
        let context = try makeContext()
        let responses = try fixture(childId: UUID())

        EntryCache.upsert(responses, into: context)
        EntryCache.upsert(responses, into: context)

        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == Self.count)
        // Backscrolling re-reads pages, and a duplicate row is the most visible possible bug.
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == (Self.count + 2) / 3)
    }

    @Test("flattening and grouping five hundred rows is one pass, not five hundred lookups")
    func buildsRowsInOnePass() throws {
        let context = try makeContext()
        let child = UUID()
        EntryCache.upsert(try fixture(childId: child), into: context)

        let entries = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate { $0.childId == child && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        ))
        let media = try context.fetch(FetchDescriptor<Media>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))

        // UTC, because the fixture's timestamps are built in UTC. Grouping in the machine's own
        // zone would split a pair across midnight on some runners and not others, and a test
        // that passes in New York and fails in London is a worse test than no test.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        let began = ContinuousClock.now
        // Exactly what `TimelineList` does per render: group the media once, then map.
        let byEntry = Dictionary(grouping: media, by: \.entryId)
        let cards = entries.map { EntryCardModel(entry: $0, media: byEntry[$0.id] ?? []) }
        let groups = TimelineGrouping.days(cards, calendar: utc, occurredAt: \.occurredAt)
        let elapsed = ContinuousClock.now - began

        #expect(cards.count == Self.count)
        // Two entries per day across the fixture.
        #expect(groups.count == Self.count / 2)
        #expect(groups.contains { $0.yearDivider != nil }, "the fixture crosses into 2025")
        #expect(elapsed < .milliseconds(500), "\(elapsed) to build and group \(Self.count) rows")
    }

    @Test("a filtered view of five hundred entries is still one query")
    func filtersInTheStore() throws {
        let context = try makeContext()
        let child = UUID()
        EntryCache.upsert(try fixture(childId: child), into: context)

        let wanted: String? = TimelineFilter.photo.queryValue
        let photos = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entry.childId == child && entry.deletedAt == nil && entry.entryType == wanted
            },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        ))

        #expect(photos.count == (Self.count + 2) / 3)
        // Same answer the server would give, which is the whole point of the offline filter.
        #expect(photos.allSatisfy { TimelineFilter.photo.matches(entryType: $0.entryType) })
    }
}
