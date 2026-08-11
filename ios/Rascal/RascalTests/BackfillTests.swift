import Foundation
import Testing

@testable import Rascal

/// Phase 18 — camera-roll backfill.
///
/// The assertion that matters most is `occurredAtComesFromTheAssetNotToday`. A backfilled photo
/// filed under this week looks completely normal and is wrong permanently — it is the one error
/// class this whole feature exists to fix, and it is invisible once shipped.

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Detroit")!
    return c
}()

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, zone: String = "America/Detroit") -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    return cal.date(from: c)!
}

// MARK: - occurred_at

@Suite("Backfill — occurred_at")
struct BackfillDateTests {

    /// **The assertion this feature exists for.**
    @Test("occurred_at comes from the asset's creation date, not from today")
    func occurredAtComesFromTheAssetNotToday() {
        let october = BackfillMonth(year: 2019, month: 10)
        let taken = date(2019, 10, 14, hour: 15)

        let resolved = BackfillDateRule.resolve(
            creationDates: [taken], month: october, calendar: calendar
        )

        #expect(resolved.date == taken)
        #expect(resolved.source == .assetCreationDate)
        // Stated separately and deliberately: whatever else changes, it is not now.
        #expect(abs(resolved.date.timeIntervalSinceNow) > 60 * 60 * 24 * 365)
    }

    /// The timezone fixture the phase asks for: the asset's local date and the device's differ.
    @Test("A timezone where the local date and the asset date differ still files by the asset")
    func timezoneFixture() {
        let october = BackfillMonth(year: 2019, month: 10)
        // 2019-10-01 01:00 in Tokyo is 2019-09-30 12:00 in Detroit. The instant is the same;
        // only the calendar it is read in differs, and the entry must follow the asset.
        let takenInTokyo = date(2019, 10, 1, hour: 1, zone: "Asia/Tokyo")

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let resolved = BackfillDateRule.resolve(
            creationDates: [takenInTokyo], month: october, calendar: tokyo
        )

        #expect(resolved.date == takenInTokyo)
        #expect(resolved.source == .assetCreationDate)
    }

    @Test("Missing metadata falls back to the backfilled month, never to today")
    func missingMetadataFallsBackToTheMonth() {
        let october = BackfillMonth(year: 2019, month: 10)

        let resolved = BackfillDateRule.resolve(
            creationDates: [nil, nil], month: october, calendar: calendar
        )

        #expect(resolved.source == .backfilledMonth)
        #expect(BackfillMonth(containing: resolved.date, calendar: calendar) == october)
        #expect(abs(resolved.date.timeIntervalSinceNow) > 60 * 60 * 24 * 365)
    }

    @Test("A date outside the month being backfilled is treated as invalid, not trusted")
    func clearlyInvalidMetadataIsRefused() {
        let october = BackfillMonth(year: 2019, month: 10)
        // Epoch zero — a broken import, or metadata edited to nothing.
        let resolved = BackfillDateRule.resolve(
            creationDates: [Date(timeIntervalSince1970: 0)], month: october, calendar: calendar
        )

        #expect(resolved.source == .backfilledMonth)
        #expect(BackfillMonth(containing: resolved.date, calendar: calendar) == october)
    }

    @Test("The earliest usable date wins, and one missing date does not drag the entry forward")
    func earliestWins() {
        let october = BackfillMonth(year: 2019, month: 10)
        let early = date(2019, 10, 3)
        let late = date(2019, 10, 28)

        let resolved = BackfillDateRule.resolve(
            creationDates: [late, nil, early], month: october, calendar: calendar
        )

        #expect(resolved.date == early)
        #expect(resolved.source == .assetCreationDate)
    }

    /// The month fallback is midday, so reading it further west cannot roll it into the previous
    /// month — which would make the fallback itself the bug it exists to prevent.
    @Test("The month fallback survives being read in a western timezone")
    func monthFallbackSurvivesTimezoneShift() {
        let october = BackfillMonth(year: 2019, month: 10)
        let fallback = october.fallbackDate(calendar: calendar)

        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        #expect(BackfillMonth(containing: fallback, calendar: honolulu) == october)
    }
}

// MARK: - The scan

@Suite("Backfill — the scan")
struct BackfillPlanTests {

    @Test("A month with photos and no entries is offered")
    func emptyMonthIsOffered() {
        let clusters = BackfillPlan.clusters(
            assetDates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)],
            entryDates: [],
            calendar: calendar
        )

        #expect(clusters.count == 1)
        #expect(clusters[0].month == BackfillMonth(year: 2019, month: 10))
        #expect(clusters[0].assetCount == 3)
    }

    @Test("A month that already has an entry is not offered")
    func writtenMonthIsNotOffered() {
        let clusters = BackfillPlan.clusters(
            assetDates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)],
            entryDates: [date(2019, 10, 20)],
            calendar: calendar
        )

        #expect(clusters.isEmpty)
    }

    @Test("A dismissed month is not re-offered")
    func dismissedMonthIsNotReoffered() {
        let assets = [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)]

        #expect(BackfillPlan.clusters(assetDates: assets, entryDates: [], calendar: calendar).count == 1)
        #expect(
            BackfillPlan.clusters(
                assetDates: assets, entryDates: [], dismissed: ["2019-10"], calendar: calendar
            ).isEmpty
        )
    }

    @Test("A month with one stray photo is not a month you failed to write up")
    func tinyMonthsAreNotOffered() {
        let clusters = BackfillPlan.clusters(
            assetDates: [date(2019, 10, 3)], entryDates: [], calendar: calendar
        )
        #expect(clusters.isEmpty)
    }

    @Test("Clusters come back newest first")
    func newestFirst() {
        let clusters = BackfillPlan.clusters(
            assetDates: [
                date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5),
                date(2021, 3, 3), date(2021, 3, 4), date(2021, 3, 5),
            ],
            entryDates: [],
            calendar: calendar
        )

        #expect(clusters.map(\.month) == [
            BackfillMonth(year: 2021, month: 3),
            BackfillMonth(year: 2019, month: 10),
        ])
    }

    @Test("iCloud-only assets are counted and reported separately, never presented as available")
    func cloudOnlyIsCountedHonestly() {
        let clusters = BackfillPlan.clusters(
            assetDates: [date(2019, 10, 3), date(2019, 10, 4)],
            cloudOnlyDates: [date(2019, 10, 5)],
            entryDates: [],
            calendar: calendar
        )

        #expect(clusters[0].assetCount == 3)
        #expect(clusters[0].cloudOnlyCount == 1)
    }
}

// MARK: - The scanner

/// Records how far the scan got, so cancellation can be asserted rather than eyeballed.
private final class StubAssetSource: BackfillAssetSource, @unchecked Sendable {
    private let lock = NSLock()
    private let auth: BackfillAuthorization
    private let dates: [Date]
    private let cloud: [Date]
    private let delay: Bool
    private var _started = false

    init(
        auth: BackfillAuthorization = .authorized,
        dates: [Date] = [],
        cloud: [Date] = [],
        delay: Bool = false
    ) {
        self.auth = auth
        self.dates = dates
        self.cloud = cloud
        self.delay = delay
    }

    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }

    func authorization() async -> BackfillAuthorization { auth }
    func libraryToken() async -> String? { nil }

    func creationDates() async throws -> (onDevice: [Date], cloudOnly: [Date]) {
        lock.lock(); _started = true; lock.unlock()
        if delay {
            // Yields rather than sleeps, so cancellation is observed deterministically and the
            // test never races a fixed interval.
            for _ in 0..<50 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        return (dates, cloud)
    }
}

@MainActor
@Suite("Backfill — the scanner")
struct BackfillScannerTests {

    private func scanner(
        _ source: StubAssetSource,
        dismissals: BackfillDismissalStoring = InMemoryBackfillDismissalStore()
    ) -> BackfillScanner {
        BackfillScanner(source: source, dismissals: dismissals, cache: InMemoryBackfillScanCache())
    }

    @Test("A completed scan reports its clusters")
    func completedScanReports() async {
        let source = StubAssetSource(
            dates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)]
        )
        let model = scanner(source)

        model.scan(entryDates: [])
        await until { if case .ready = model.state { return true }; return false }

        guard case .ready(let clusters) = model.state else {
            Issue.record("expected a ready state")
            return
        }
        #expect(clusters.count == 1)
    }

    /// **Limited access is a working scan, not an error.**
    @Test("Limited photo library access scans what it can see and says so")
    func limitedAccessScans() async {
        let source = StubAssetSource(
            auth: .limited, dates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)]
        )
        let model = scanner(source)

        model.scan(entryDates: [])
        await until { if case .ready = model.state { return true }; return false }

        #expect(model.isLimitedLibrary)
        if case .ready(let clusters) = model.state {
            #expect(clusters.count == 1)
        } else {
            Issue.record("limited access produced no result")
        }
    }

    @Test("Denied access is unavailable rather than an error state to recover from")
    func deniedIsUnavailable() async {
        let model = scanner(StubAssetSource(auth: .denied))

        model.scan(entryDates: [])
        await until { model.state == .unavailable }

        #expect(model.state == .unavailable)
    }

    @Test("A cancelled scan leaves no partial state")
    func cancellationLeavesNoPartialState() async {
        let source = StubAssetSource(
            dates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)], delay: true
        )
        let model = scanner(source)

        model.scan(entryDates: [])
        await until { source.started }
        model.cancel()

        // Whatever else is true, it never publishes a half-built list.
        for _ in 0..<20 { await Task.yield() }
        if case .ready = model.state {
            Issue.record("a cancelled scan published a result")
        }
    }

    @Test("Dismissing a month removes it and it does not come back")
    func dismissalSticks() async {
        let dismissals = InMemoryBackfillDismissalStore()
        let dates = [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)]
        let model = scanner(StubAssetSource(dates: dates), dismissals: dismissals)

        model.scan(entryDates: [])
        await until { if case .ready = model.state { return true }; return false }
        model.dismiss(BackfillMonth(year: 2019, month: 10))

        if case .ready(let clusters) = model.state {
            #expect(clusters.isEmpty)
        }

        // And a fresh scanner reading the same store does not re-offer it.
        let second = BackfillScanner(
            source: StubAssetSource(dates: dates),
            dismissals: dismissals,
            cache: InMemoryBackfillScanCache()
        )
        second.scan(entryDates: [])
        await until { if case .ready = second.state { return true }; return false }
        if case .ready(let clusters) = second.state {
            #expect(clusters.isEmpty)
        }
    }
}

/// Polls for a condition. **Never sleeps a fixed interval** — timer-based tests have passed alone
/// and failed inside the full suite in this repo before.
@MainActor
private func until(
    _ condition: @MainActor () -> Bool,
    iterations: Int = 2000
) async {
    for _ in 0..<iterations {
        if condition() { return }
        await Task.yield()
    }
}

// MARK: - The rule that must not break

@Suite("Backfill — never an assignment")
struct BackfillEntryPlanTests {

    /// **Asserted directly, as the phase requires.**
    ///
    /// The server owns the schedule. A backfill built from this phone's camera roll is something
    /// the server cannot know about, so it must never look like something the server served.
    @MainActor
    @Test("No assignment is ever created by the backfill path")
    func noAssignmentIsEverCreated() {
        let plan = BackfillEntryPlan(
            month: BackfillMonth(year: 2019, month: 10),
            creationDates: [date(2019, 10, 3), date(2019, 10, 4)],
            calendar: calendar
        )

        let request = plan.composerRequest(childId: UUID())

        #expect(request.assignment == nil)
        // Structural, not remembered: the plan has no field that could hold one, so no future
        // edit can pass an assignment through without adding one deliberately.
        #expect(Mirror(reflecting: plan).children.allSatisfy { $0.label != "assignment" })
    }

    @Test("A selection produces one entry carrying several media")
    func oneEntryPerSelection() {
        let plan = BackfillEntryPlan(
            month: BackfillMonth(year: 2019, month: 10),
            creationDates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)],
            calendar: calendar
        )

        #expect(plan.assetCount == 3)
        #expect(BackfillEntryPlan.suggestedSelectionCount == 3)
    }

    @Test("A defaulted date is flagged so the composer can say so")
    func defaultedDateIsVisible() {
        let defaulted = BackfillEntryPlan(
            month: BackfillMonth(year: 2019, month: 10), creationDates: [nil], calendar: calendar
        )
        let real = BackfillEntryPlan(
            month: BackfillMonth(year: 2019, month: 10),
            creationDates: [date(2019, 10, 9)],
            calendar: calendar
        )

        #expect(defaulted.isDateDefaulted)
        #expect(real.isDateDefaulted == false)
    }
}
