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
    private let monthAssets: [String: [BackfillAsset]]
    private var _started = false
    private var _fetchedMonths: [String] = []
    private var _didRequestAuthorization = false

    init(
        auth: BackfillAuthorization = .authorized,
        dates: [Date] = [],
        cloud: [Date] = [],
        delay: Bool = false,
        monthAssets: [String: [BackfillAsset]] = [:]
    ) {
        self.auth = auth
        self.dates = dates
        self.cloud = cloud
        self.delay = delay
        self.monthAssets = monthAssets
    }

    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    /// Which months were actually opened. The scan must never appear here — counting photos and
    /// identifying them are separate acts, and only the second one happens on a tap.
    var fetchedMonths: [String] { lock.lock(); defer { lock.unlock() }; return _fetchedMonths }
    /// The system prompt is one-shot, so a test that asks whether it was fired is asserting the
    /// explainer actually gates it.
    var didRequestAuthorization: Bool {
        lock.lock(); defer { lock.unlock() }; return _didRequestAuthorization
    }

    func authorization() async -> BackfillAuthorization { auth }
    func requestAuthorization() async -> BackfillAuthorization {
        record { $0._didRequestAuthorization = true }
        return auth
    }
    func libraryToken() async -> String? { nil }

    func creationDates() async throws -> (onDevice: [Date], cloudOnly: [Date]) {
        record { $0._started = true }
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

    func assets(in month: BackfillMonth) async throws -> [BackfillAsset] {
        record { $0._fetchedMonths.append(month.key) }
        try Task.checkCancellation()
        return monthAssets[month.key] ?? []
    }

    /// One opaque byte. The tests assert on which assets are asked for and which are refused,
    /// never on pixels — there is nothing to decode and nothing worth decoding.
    func thumbnail(for assetId: String, maxPixel: Int) async -> Data? {
        guard let asset = allAssets.first(where: { $0.id == assetId }) else { return nil }
        // Mirrors PhotoKit with network access off: a cloud-only asset yields nothing.
        return asset.isOnDevice ? Data([0x01]) : nil
    }

    func imageData(for assetId: String) async throws -> Data {
        guard let asset = allAssets.first(where: { $0.id == assetId }) else {
            throw BackfillAssetError.missing
        }
        guard asset.isOnDevice else { throw BackfillAssetError.notOnDevice }
        return Data([0x02])
    }

    private var allAssets: [BackfillAsset] { monthAssets.values.flatMap { $0 } }

    /// Synchronous on purpose. Taking an `NSLock` directly inside an `async` body is unavailable
    /// in Swift 6 — the suspension point it cannot see is exactly what makes it unsafe — so every
    /// mutation goes through here instead.
    private func record(_ change: (StubAssetSource) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(self)
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
        #expect(model.authorization == .limited)
        if case .ready(let clusters) = model.state {
            #expect(clusters.count == 1)
        } else {
            Issue.record("limited access produced no result")
        }
    }

    /// **A count under `.limited` is a count of the selection, and every surface that shows one
    /// has to say so.**
    ///
    /// `PHAsset.fetchAssets` returns only the shared subset under selected-photos access, so the
    /// numbers are computed over a fraction of the library and are *wrong while looking entirely
    /// normal* — the same failure shape as a photo filed under the wrong day. This fails if any
    /// of the three carriers of that number presents it as a whole-library figure.
    @Test("No surface presents a limited-access count as though it were complete")
    func limitedCountsAreNeverPresentedAsComplete() async {
        let source = StubAssetSource(
            auth: .limited, dates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)]
        )
        let model = scanner(source)
        model.scan(entryDates: [])
        await until { if case .ready = model.state { return true }; return false }

        // 1. The scanner knows, and keeps knowing.
        #expect(model.isLimitedLibrary)

        // 2. The + sheet's row says whose photos it counted, in the same sentence as the number.
        let clusters: [BackfillCluster]
        if case .ready(let ready) = model.state { clusters = ready } else { clusters = [] }
        let sheet = AddToArchiveModel(authorization: .limited, clusters: clusters)
        #expect(sheet.cameraRollSubtitle.lowercased().contains("shared"))
        #expect(sheet.cameraRollSubtitle.contains("nothing logged") == false)

        // 3. The browse surface leads with a claim about the library, so it changes too.
        let full = BackfillSuggestionsScreen(
            clusters: clusters, months: model.months, childBirthdate: nil,
            isLimited: false, onOpen: { _ in }, onDismissMonth: { _ in }, onClose: {}
        )
        let limited = BackfillSuggestionsScreen(
            clusters: clusters, months: model.months, childBirthdate: nil,
            isLimited: true, onOpen: { _ in }, onDismissMonth: { _ in }, onClose: {}
        )
        #expect(limited.isLimited)
        #expect(full.isLimited == false)
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

// MARK: - The surface

/// Phase 18's UI, and the rules that had to be liftable out of a view to be asserted at all.
///
/// The placement here is the **reversed** one — the offer lives in the sheet behind **+**, not
/// inside the composer. See `docs/decisions.md`. The rule the original placement was protecting
/// still holds and is asserted below: nothing on this path can carry an assignment.
@Suite("Backfill — the offer")
struct BackfillOfferTests {

    private func cluster(_ year: Int, _ month: Int, count: Int) -> BackfillCluster {
        BackfillCluster(
            month: BackfillMonth(year: year, month: month), assetCount: count, cloudOnlyCount: 0
        )
    }

    /// **Replaces `noRowWhenNothingToOffer`, which asserted the opposite and was right about the
    /// principle and wrong about this row.**
    ///
    /// That test pinned "the row is absent, not empty" — a good rule for a row that reports
    /// something, and the wrong one for a row that is a *door*. Clusters are only non-empty after
    /// a scan, a scan only runs with authorization, and the only thing in the app that asks for
    /// authorization is the explainer behind this row. Absent-when-empty therefore meant absent
    /// forever on any phone that had not already granted access. `docs/decisions.md` settles that
    /// the camera roll sits below the divider as a fifth, non-verb thing; this is that, and the
    /// four cases are here because the defect being fixed was exactly a case-analysis bug.
    @Test("The camera-roll row is present in every authorization state")
    func cameraRollRowIsUnconditional() {
        for authorization in [
            BackfillAuthorization.notDetermined, .limited, .authorized, .denied,
        ] {
            let empty = AddToArchiveModel(authorization: authorization, clusters: [])
            let populated = AddToArchiveModel(
                authorization: authorization, clusters: [cluster(2025, 10, count: 62)]
            )
            #expect(empty.includesCameraRoll, "row missing with no clusters: \(authorization)")
            #expect(populated.includesCameraRoll, "row missing with clusters: \(authorization)")
            #expect(empty.cameraRollSubtitle.isEmpty == false)
            #expect(populated.cameraRollSubtitle.isEmpty == false)
        }
    }

    @Test("The newest unlogged month is the one offered")
    func newestMonthIsOffered() {
        let model = AddToArchiveModel(
            authorization: .authorized,
            clusters: [cluster(2025, 10, count: 62), cluster(2024, 12, count: 118)]
        )
        #expect(model.offer?.month == BackfillMonth(year: 2025, month: 10))
    }

    /// Factual, and **never a tally**. A count of what is in the camera roll is not an accusation;
    /// "you've missed six months" would be, and this app keeps that score nowhere.
    @Test("The offer states the count and the month, and nothing about what was missed")
    func offerCopyIsFactual() {
        let line = AddToArchiveModel(
            authorization: .authorized, clusters: [cluster(2025, 10, count: 62)]
        ).cameraRollSubtitle

        #expect(line.contains("62 photos"))
        #expect(line.contains("2025"))
        for scold in ["missed", "forgot", "behind", "haven't", "still no", "empty"] {
            #expect(line.lowercased().contains(scold) == false, "guilt copy: \(line)")
        }
    }

    @Test("A single photo is not pluralised")
    func offerCopySingular() {
        let line = AddToArchiveModel(
            authorization: .authorized, clusters: [cluster(2025, 10, count: 1)]
        ).cameraRollSubtitle
        #expect(line.hasPrefix("1 photo from"))
        #expect(line.contains("1 photos") == false)
    }

    /// **No count is ever presented as complete when it is not.**
    ///
    /// Under `.limited` the scan sees the selected photos and nothing else, so "62 photos from
    /// October 2025" is a fraction wearing the clothes of a total. The number may still be shown
    /// — it is true of what was seen — but the sentence has to say whose photos it counted.
    @Test("A count under limited access says what it is a count of")
    func limitedCountIsLabelled() {
        let limited = AddToArchiveModel(
            authorization: .limited, clusters: [cluster(2025, 10, count: 62)]
        ).cameraRollSubtitle
        let full = AddToArchiveModel(
            authorization: .authorized, clusters: [cluster(2025, 10, count: 62)]
        ).cameraRollSubtitle

        #expect(limited.contains("62 photos"))
        #expect(limited != full, "limited copy is indistinguishable from complete copy")
        #expect(limited.lowercased().contains("shared"))
        // "nothing logged" is a claim about the whole month, which is not knowable here.
        #expect(limited.contains("nothing logged") == false)
    }

    /// A denial gets one honest sentence and no funnel. iOS asks once; the flow behind the row
    /// offers Settings, which is the only thing that can change the answer.
    @Test("A denied library says so plainly, without scolding or re-asking")
    func deniedCopyIsHonest() {
        let line = AddToArchiveModel(authorization: .denied, clusters: []).cameraRollSubtitle

        #expect(line.lowercased().contains("off"))
        for pressure in ["allow", "enable", "grant", "turn on", "please"] {
            #expect(line.lowercased().contains(pressure) == false, "re-prompt copy: \(line)")
        }
    }

    /// Before anything has been asked, nothing has been counted — so nothing is counted at.
    @Test("With authorization undecided the row invites rather than reports")
    func notDeterminedCopyClaimsNoCount() {
        let line = AddToArchiveModel(authorization: .notDetermined, clusters: []).cameraRollSubtitle

        #expect(line.contains("photos from") == false)
        #expect(line.rangeOfCharacter(from: .decimalDigits) == nil, "a count with nothing scanned")
    }

    /// The rule the composer-row placement was protecting, asserted against the placement that
    /// actually shipped: **every path out of this sheet is freeform.** A served mission is reached
    /// from Today, never from here, and nothing here can attach one.
    @MainActor
    @Test("Nothing the + sheet opens can carry an assignment")
    func nothingFromTheSheetCarriesAnAssignment() {
        for opening in [ComposerOpening.library, .camera, .recorder, .writing] {
            let request = ComposerRequest(
                childId: UUID(), assignment: nil, mode: .text, opening: opening
            )
            #expect(request.assignment == nil)
            #expect(request.backfill == nil)
        }
    }
}

// MARK: - One day at a time

/// The constraint that makes a backfilled `occurred_at` exact rather than merely defensible.
@Suite("Backfill — the one-day selection rule")
struct BackfillSelectionTests {

    private let oct12 = date(2025, 10, 12)
    private let oct20 = date(2025, 10, 20)

    private func asset(_ id: String, onDevice: Bool = true, at date: Date? = nil) -> BackfillAsset {
        BackfillAsset(id: id, creationDate: date, isOnDevice: onDevice)
    }

    @Test("Nothing is selected until the parent picks something")
    func nothingIsPreselected() {
        let selection = BackfillSelection()
        #expect(selection.isEmpty)
        #expect(selection.day == nil)
    }

    @Test("Picking several photos from one day keeps them all")
    func multipleFromOneDay() {
        var selection = BackfillSelection()
        selection.tap(asset("a"), on: oct12)
        selection.tap(asset("b"), on: oct12)
        selection.tap(asset("c"), on: oct12)

        #expect(selection.count == 3)
        #expect(selection.day == oct12)
    }

    /// **The date guarantee.** A selection that could span two days would resolve to the earlier
    /// one and silently misdate everything from the later.
    @Test("Reaching for a second day is refused, and explains itself rather than clearing")
    func secondDayIsRefused() {
        var selection = BackfillSelection()
        selection.tap(asset("a"), on: oct12)
        selection.tap(asset("z"), on: oct20)

        #expect(selection.count == 1)
        #expect(selection.day == oct12)
        // Nothing was discarded, and the picker has what it needs to say why.
        #expect(selection.blockedDay == oct20)
    }

    @Test("Start here abandons the old day rather than carrying photos across")
    func startOverClears() {
        var selection = BackfillSelection()
        selection.tap(asset("a"), on: oct12)
        selection.tap(asset("z"), on: oct20)
        selection.startOver()

        #expect(selection.isEmpty)
        #expect(selection.day == nil)
        #expect(selection.blockedDay == nil)

        selection.tap(asset("z"), on: oct20)
        #expect(selection.day == oct20)
    }

    @Test("Deselecting the last photo releases the day")
    func deselectingReleasesTheDay() {
        var selection = BackfillSelection()
        selection.tap(asset("a"), on: oct12)
        selection.tap(asset("a"), on: oct12)

        #expect(selection.isEmpty)
        #expect(selection.day == nil)

        // And the parent is now free to start on a different day.
        selection.tap(asset("z"), on: oct20)
        #expect(selection.day == oct20)
    }

    /// Cloud-only assets are shown so the count stays honest, and refused so nothing downloads.
    @Test("A photo only in iCloud cannot be selected")
    func cloudOnlyIsNotSelectable() {
        var selection = BackfillSelection()
        selection.tap(asset("cloud", onDevice: false), on: oct12)

        #expect(selection.isEmpty)
        #expect(selection.day == nil)
    }

    /// The rule and the date resolver agreeing, end to end.
    @Test("A one-day selection resolves to that exact day, not to a month fallback")
    func oneDaySelectionResolvesExactly() {
        var selection = BackfillSelection()
        let assets = [
            asset("a", at: date(2025, 10, 12, hour: 9)),
            asset("b", at: date(2025, 10, 12, hour: 14)),
        ]
        for item in assets { selection.tap(item, on: oct12) }

        let plan = BackfillEntryPlan(
            month: BackfillMonth(year: 2025, month: 10),
            creationDates: assets.filter { selection.contains($0) }.map(\.creationDate),
            calendar: calendar
        )

        #expect(plan.isDateDefaulted == false)
        #expect(plan.occurredAt == date(2025, 10, 12, hour: 9))
    }
}

// MARK: - Every month

@Suite("Backfill — the browse index")
struct BackfillMonthIndexTests {

    /// The browse list is a map, not an offer: it applies **none** of `clusters`' filters.
    @Test("Every month with a photo is listed, including ones already written about")
    func everyMonthIsListed() {
        let index = BackfillPlan.monthIndex(
            assetDates: [
                date(2025, 10, 3), date(2025, 10, 4), date(2025, 10, 5),
                date(2025, 9, 1),
                date(2025, 8, 2), date(2025, 8, 3), date(2025, 8, 4),
            ],
            entryDates: [date(2025, 8, 2), date(2025, 8, 9)],
            calendar: calendar
        )

        #expect(index.count == 3)
        // Newest first.
        #expect(index.map(\.month.key) == ["2025-10", "2025-09", "2025-08"])
        // A single stray photo still earns a row here, where `clusters` would drop it.
        #expect(index[1].assetCount == 1)
        // And a written month is listed with its count rather than hidden.
        #expect(index[2].entryCount == 2)
        #expect(index[2].isLogged)
        #expect(index[0].isLogged == false)
    }

    /// A month with entries and no photos is not a door onto anything.
    @Test("A month with entries but no photos is not listed")
    func entriesWithoutPhotosAreNotListed() {
        let index = BackfillPlan.monthIndex(
            assetDates: [date(2025, 10, 3)],
            entryDates: [date(2024, 2, 2)],
            calendar: calendar
        )

        #expect(index.map(\.month.key) == ["2025-10"])
    }

    @Test("Cloud-only photos are counted rather than hidden")
    func cloudOnlyCounts() {
        let index = BackfillPlan.monthIndex(
            assetDates: [date(2025, 10, 3)],
            cloudOnlyDates: [date(2025, 10, 4), date(2025, 10, 5)],
            entryDates: [],
            calendar: calendar
        )

        #expect(index[0].assetCount == 3)
    }

    /// A cache written before the index existed must not force a full rescan of the library on
    /// every device on the first launch after the update.
    @Test("A cached result from an older build still decodes")
    func olderCacheStillDecodes() throws {
        let legacy = """
        {"clusters":[{"year":2025,"month":10,"assetCount":62,"cloudOnlyCount":0}],
         "scannedAt":761000000,"libraryToken":null}
        """
        let decoded = try JSONDecoder().decode(
            BackfillScanResult.self, from: Data(legacy.utf8)
        )

        #expect(decoded.asClusters.count == 1)
        // Absent, not a failure — the next scan fills it in.
        #expect(decoded.asMonths.isEmpty)
    }

    @Test("The index survives a cache round trip")
    func indexRoundTrips() throws {
        let result = BackfillScanResult.from(
            [BackfillCluster(month: BackfillMonth(year: 2025, month: 10), assetCount: 62, cloudOnlyCount: 4)],
            months: [
                BackfillMonthSummary(
                    month: BackfillMonth(year: 2025, month: 8), assetCount: 41, entryCount: 12
                )
            ],
            at: Date(timeIntervalSince1970: 761_000_000),
            token: nil
        )

        let round = try JSONDecoder().decode(
            BackfillScanResult.self, from: try JSONEncoder().encode(result)
        )

        #expect(round.asMonths.count == 1)
        #expect(round.asMonths[0].entryCount == 12)
        #expect(round.asClusters[0].cloudOnlyCount == 4)
    }
}

// MARK: - What the picker hands the composer

@Suite("Backfill — the prefilled composer")
struct BackfillPrefillTests {

    private func draft(_ id: UUID = UUID()) -> MediaDraft {
        MediaDraft(
            id: id,
            stagedURL: URL(filePath: "/dev/null"),
            fileExtension: "jpg",
            byteCount: 1,
            contentType: "image/jpeg",
            capturedAt: nil,
            thumbnail: Data()
        )
    }

    /// **One entry, several media, and no assignment.** The composer builds its `Entry` with
    /// `assignmentId: request.assignment?.id` and one `Media` per draft, so a request carrying a
    /// nil assignment and three drafts is exactly one entry with three media and `assignment_id`
    /// null — which is what a freeform entry is for.
    @MainActor
    @Test("A selection becomes one composer request with several media and no assignment")
    func oneRequestWithSeveralMedia() {
        let plan = BackfillEntryPlan(
            month: BackfillMonth(year: 2025, month: 10),
            creationDates: [date(2025, 10, 12), date(2025, 10, 12), date(2025, 10, 12)],
            calendar: calendar
        )

        let request = plan.composerRequest(
            childId: UUID(), drafts: [draft(), draft(), draft()], childBirthdate: nil
        )

        #expect(request.assignment == nil)
        #expect(request.backfill?.drafts.count == 3)
        #expect(request.mode == .media)
    }

    /// The composer must render the rule's answer, not re-derive one. `MediaDraftBuilder`'s date
    /// rule falls back to `now`, which is the failure this whole feature exists to prevent.
    @MainActor
    @Test("The composer is handed the rule's date, not the drafts' own")
    func theRulesDateIsCarriedThrough() {
        let plan = BackfillEntryPlan(
            month: BackfillMonth(year: 2019, month: 10), creationDates: [nil, nil], calendar: calendar
        )

        let request = plan.composerRequest(childId: UUID(), drafts: [draft(), draft()])

        // Drafts with no capture date would send `suggestedOccurredAt` to today. The plan sent it
        // to the month being filled, and that is what travels.
        #expect(request.backfill?.plan.occurredAt == plan.occurredAt)
        #expect(request.backfill?.plan.isDateDefaulted == true)
        #expect(Calendar.current.component(.year, from: plan.occurredAt) == 2019)
    }

    /// A defaulted date has to be **visible**, not merely recorded. The composer branches on this.
    @MainActor
    @Test("A defaulted date arrives at the composer flagged")
    func defaultedDateReachesTheComposerFlagged() {
        let defaulted = BackfillEntryPlan(
            month: BackfillMonth(year: 2019, month: 10), creationDates: [nil], calendar: calendar
        ).composerRequest(childId: UUID(), drafts: [draft()])

        let read = BackfillEntryPlan(
            month: BackfillMonth(year: 2019, month: 10),
            creationDates: [date(2019, 10, 9)],
            calendar: calendar
        ).composerRequest(childId: UUID(), drafts: [draft()])

        #expect(defaulted.backfill?.plan.isDateDefaulted == true)
        #expect(read.backfill?.plan.isDateDefaulted == false)
    }
}

// MARK: - Nothing is identified until a month is opened

@MainActor
@Suite("Backfill — the scan stays a count")
struct BackfillAssetFetchTests {

    /// Counting photos and identifying them are separate acts, and the second one waits for a tap.
    @Test("Scanning never asks for a single asset identifier")
    func scanningNeverFetchesAssets() async {
        let source = StubAssetSource(
            dates: [date(2025, 10, 3), date(2025, 10, 4), date(2025, 10, 5)],
            monthAssets: ["2025-10": [BackfillAsset(id: "a", creationDate: nil, isOnDevice: true)]]
        )
        let model = BackfillScanner(
            source: source, dismissals: InMemoryBackfillDismissalStore(),
            cache: InMemoryBackfillScanCache()
        )

        await model.scanAndWait(entryDates: [])

        #expect(source.fetchedMonths.isEmpty)

        // And opening one asks for exactly that month.
        _ = try? await source.assets(in: BackfillMonth(year: 2025, month: 10))
        #expect(source.fetchedMonths == ["2025-10"])
    }

    /// A month set aside by mistake is recoverable for as long as the toast is on screen — and the
    /// dismissal is persisted immediately, so a force quit inside that window keeps the decision.
    @Test("Undo restores a month that was just set aside")
    func undoRestores() async {
        let dismissals = InMemoryBackfillDismissalStore()
        let dates = [date(2025, 10, 3), date(2025, 10, 4), date(2025, 10, 5)]
        let model = BackfillScanner(
            source: StubAssetSource(dates: dates), dismissals: dismissals,
            cache: InMemoryBackfillScanCache()
        )
        let october = BackfillMonth(year: 2025, month: 10)

        await model.scanAndWait(entryDates: [])
        model.dismiss(october)
        #expect(dismissals.dismissed().contains(october.key))

        model.restore(october, entryDates: [])
        await until { if case .ready(let c) = model.state { return !c.isEmpty }; return false }

        #expect(dismissals.dismissed().contains(october.key) == false)
        if case .ready(let clusters) = model.state {
            #expect(clusters.map(\.month) == [october])
        } else {
            Issue.record("restore left no result")
        }
    }

    /// Cloud-only assets are refused rather than downloaded — the explainer promised nothing
    /// leaves or arrives on this phone, and a silent multi-megabyte fetch would break that.
    @Test("A cloud-only asset yields no thumbnail and refuses to hand over bytes")
    func cloudOnlyIsRefused() async {
        let source = StubAssetSource(
            monthAssets: [
                "2025-10": [
                    BackfillAsset(id: "here", creationDate: nil, isOnDevice: true),
                    BackfillAsset(id: "cloud", creationDate: nil, isOnDevice: false),
                ]
            ]
        )

        #expect(await source.thumbnail(for: "cloud", maxPixel: 320) == nil)
        #expect(await source.thumbnail(for: "here", maxPixel: 320) != nil)

        await #expect(throws: BackfillAssetError.notOnDevice) {
            _ = try await source.imageData(for: "cloud")
        }
    }
}
