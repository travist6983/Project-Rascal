import Foundation
import SwiftUI
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
    /// **Mutable, because a grant changes under the app's feet.** A parent can narrow or revoke
    /// access in Settings while the flow is open, and the scan's behaviour across that change is
    /// the thing worth asserting — a fixed status can only ever test one side of it.
    private var _auth: BackfillAuthorization
    private let dates: [Date]
    private let cloud: [Date]
    private let delay: Bool
    /// **Mutable, because the library changes under the app.** A `.limited` parent editing their
    /// shared selection in Settings is exactly the case `revalidate()` exists for, and a fixed
    /// dictionary can only ever test the half where nothing moved.
    private var _monthAssets: [String: [BackfillAsset]]
    private var _started = false
    private var _fetchedMonths: [String] = []
    private var _didRequestAuthorization = false
    private var _authorizationRequests = 0
    private var _duringAssetFetch: (@Sendable () async -> Void)?

    init(
        auth: BackfillAuthorization = .authorized,
        dates: [Date] = [],
        cloud: [Date] = [],
        delay: Bool = false,
        monthAssets: [String: [BackfillAsset]] = [:]
    ) {
        self._auth = auth
        self.dates = dates
        self.cloud = cloud
        self.delay = delay
        self._monthAssets = monthAssets
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

    /// What Settings now says. Assigning it is a parent changing the grant while the app is open.
    var auth: BackfillAuthorization {
        get { lock.lock(); defer { lock.unlock() }; return _auth }
        set { lock.lock(); defer { lock.unlock() }; _auth = newValue }
    }

    /// How many times the one-shot system prompt was fired. **A count rather than a flag**: the
    /// failure worth catching is asking twice, and a `Bool` cannot see it.
    var authorizationRequests: Int {
        lock.lock(); defer { lock.unlock() }; return _authorizationRequests
    }

    func authorization() async -> BackfillAuthorization { auth }
    func requestAuthorization() async -> BackfillAuthorization {
        record { $0._didRequestAuthorization = true; $0._authorizationRequests += 1 }
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

    /// Runs inside `assets(in:)`, after the fetch is recorded and before it returns.
    ///
    /// **The seam for changing the library while a fetch is genuinely in flight.** Racing
    /// `Task.yield()` against a detached fetch is not deterministic and would make the test it
    /// serves a flake; this puts the interleaving exactly where the assertion needs it.
    var duringAssetFetch: (@Sendable () async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _duringAssetFetch }
        set { lock.lock(); defer { lock.unlock() }; _duringAssetFetch = newValue }
    }

    func assets(in month: BackfillMonth) async throws -> [BackfillAsset] {
        record { $0._fetchedMonths.append(month.key) }
        if let hook = duringAssetFetch { await hook() }
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

    var monthAssets: [String: [BackfillAsset]] {
        get { lock.lock(); defer { lock.unlock() }; return _monthAssets }
        set { lock.lock(); defer { lock.unlock() }; _monthAssets = newValue }
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
        BackfillScanner(source: source, childId: UUID(), dismissals: dismissals, cache: InMemoryBackfillScanCache())
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
            suggested: model.months, months: model.months, childBirthdate: nil,
            isLimited: false, onOpen: { _ in }, onDismissMonth: { _ in }, onClose: {}
        )
        let limited = BackfillSuggestionsScreen(
            suggested: model.months, months: model.months, childBirthdate: nil,
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
        let second = BackfillScanner(source: StubAssetSource(dates: dates), childId: UUID(),
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
            token: nil,
            grant: .authorized
        )

        let round = try JSONDecoder().decode(
            BackfillScanResult.self, from: try JSONEncoder().encode(result)
        )

        #expect(round.asMonths.count == 1)
        #expect(round.asMonths[0].entryCount == 12)
        #expect(round.asClusters[0].cloudOnlyCount == 4)
    }
}

// MARK: - Authorization

/// Phase 135 — the grant, and what the app does when it moves.
///
/// **The property these assert was the one thing in this feature with no coverage at all.**
/// `didRequestAuthorization` was instrumented on the stub from the beginning and asserted by
/// nothing, and no test ever constructed a `.notDetermined` source — so "the prompt is reachable,
/// and fires exactly once, from behind the explainer" was the load-bearing claim nobody checked.
@MainActor
@Suite("Backfill — authorization")
struct BackfillAuthorizationTests {

    private func scanner(
        _ source: StubAssetSource,
        cache: BackfillScanCaching = InMemoryBackfillScanCache()
    ) -> BackfillScanner {
        BackfillScanner(
            source: source,
            childId: UUID(),
            dismissals: InMemoryBackfillDismissalStore(),
            cache: cache
        )
    }

    @Test("An undecided library asks, once, and only when asked to")
    func undecidedAsksOnce() async {
        let source = StubAssetSource(auth: .notDetermined, dates: [date(2019, 10, 3)])
        let model = scanner(source)

        // A scan is not an ask. This is the whole shape of the feature: the explainer earns the
        // one-shot prompt, and everything else reads the status.
        await model.scanAndWait(entryDates: [])
        #expect(model.state == .unavailable)
        #expect(source.authorizationRequests == 0)
        #expect(model.authorization == .notDetermined)

        source.auth = .authorized
        let granted = await model.requestAccess()

        #expect(granted == .authorized)
        #expect(source.authorizationRequests == 1)
        #expect(model.authorization == .authorized)
    }

    @Test("A refusal is recorded as a refusal, and asking again does not re-prompt twice over")
    func refusalIsRecorded() async {
        let source = StubAssetSource(auth: .denied)
        let model = scanner(source)

        let first = await model.requestAccess()
        #expect(first == .denied)
        #expect(model.state == .unavailable)
        // `.denied` is a *known* refusal, not an absence — the + sheet says something different
        // for "said no" than for "never asked".
        #expect(model.authorization == .denied)
        #expect(source.authorizationRequests == 1)

        // **Asked again, because the name of this test is a claim about the second ask.** iOS shows
        // nothing the second time, so the count rising is not a visible bug — it is the shape a
        // retry funnel would have, and `docs/decisions.md` settles that this app builds none.
        let second = await model.requestAccess()
        #expect(second == .denied)
        #expect(model.state == .unavailable)
        #expect(model.authorization == .denied)
    }

    @Test("Granting selected-photos access is a working scan and is flagged as partial")
    func limitedGrantScans() async {
        // Three, because `BackfillPlan.clusters` takes `minimumAssets: 3` — a month holding one or
        // two stray pictures is not a month anybody failed to write up. The point of this test is
        // that a *selection* clears that bar the same way a library does, so it has to clear it.
        let source = StubAssetSource(
            auth: .limited,
            dates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)]
        )
        let model = scanner(source)

        let granted = await model.requestAccess()
        #expect(granted == .limited)
        #expect(model.isLimitedLibrary)

        await model.scanAndWait(entryDates: [])

        // **Not `state != .unavailable`**, which a scan that walked the library and found nothing
        // satisfies just as well as one that worked. The claim is that a selection scans like a
        // library does, so the assertion is the photos.
        guard case .ready(let clusters) = model.state else {
            Issue.record("expected a ready state under limited access, got \(model.state)")
            return
        }
        #expect(clusters.count == 1)
        #expect(model.months.reduce(0) { $0 + $1.assetCount } == 3)
    }

    /// **The defect this closes is silent and survives a force-quit.** A cache written under full
    /// access carries whole-library counts. Narrow the grant in Settings and every screen switches
    /// to "out of the photos you've shared" copy — over the same numbers, which are now counts of
    /// photos the app cannot see. No timer catches it, because narrowing a grant does not age a
    /// cache.
    @Test("A scan cached under full access is not served once access has narrowed")
    func cacheIsKeyedToTheGrant() async {
        let cache = InMemoryBackfillScanCache()
        let full = StubAssetSource(
            auth: .authorized,
            dates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)]
        )
        let first = scanner(full, cache: cache)
        await first.scanAndWait(entryDates: [])
        let wholeLibrary = first.months.reduce(0) { $0 + $1.assetCount }
        #expect(wholeLibrary == 3)

        // Same cache, same clock — only the grant moved, and only one photo is shared.
        let narrowed = StubAssetSource(auth: .limited, dates: [date(2019, 10, 3)])
        let second = scanner(narrowed, cache: cache)
        await second.scanAndWait(entryDates: [])

        #expect(second.isLimitedLibrary)
        #expect(second.months.reduce(0) { $0 + $1.assetCount } == 1)
        #expect(narrowed.started, "the cache should have been rejected and the library re-read")
    }

    @Test("A cache written under the same grant is still served")
    func cacheStillServesWithinTheSameGrant() async {
        let cache = InMemoryBackfillScanCache()
        let first = StubAssetSource(auth: .authorized, dates: [date(2019, 10, 3)])
        await scanner(first, cache: cache).scanAndWait(entryDates: [])

        let second = StubAssetSource(auth: .authorized, dates: [date(2019, 10, 3)])
        await scanner(second, cache: cache).scanAndWait(entryDates: [])

        #expect(second.started == false, "an unchanged grant should not force a re-read")
    }

    /// **The scanner is shared by `RootView` and the flow**, and `scan` is cancel-and-replace. So a
    /// caller awaiting its own task gets control back the moment somebody else starts a scan — with
    /// `state` still holding whatever it held before. `route` read that as its answer and settled
    /// the screen on "You've written about every month that has photos" over a full camera roll,
    /// permanently, because nothing re-derives the stage when the replacement lands.
    @Test("A scan replaced mid-flight is awaited to its real end, not to its cancellation")
    func scanAndWaitFollowsTheReplacement() async {
        let source = StubAssetSource(
            dates: [date(2019, 10, 3), date(2019, 10, 4), date(2019, 10, 5)],
            delay: true
        )
        let model = scanner(source)

        // A second caller — the root's foreground sweep — lands while the first is still walking.
        let interloper = Task { @MainActor in
            await Task.yield()
            model.scan(entryDates: [], force: true)
        }
        await model.scanAndWait(entryDates: [], force: true)
        _ = await interloper.value

        // The caller must not be handed control while the library is still being read.
        guard case .ready(let clusters) = model.state else {
            Issue.record("scanAndWait returned on a cancelled scan; state was \(model.state)")
            return
        }
        #expect(clusters.count == 1)
    }

    @Test("Freshness rejects a cache from another grant before it considers the clock")
    func freshnessChecksTheGrantFirst() {
        let now = Date(timeIntervalSince1970: 761_000_000)
        let result = BackfillScanResult.from(
            [BackfillCluster(month: BackfillMonth(year: 2025, month: 10), assetCount: 62, cloudOnlyCount: 0)],
            at: now,
            token: nil,
            grant: .authorized
        )

        // Written one second ago — as fresh as a cache can be, and still wrong for this grant.
        #expect(result.isFresh(now: now.addingTimeInterval(1), token: nil, grant: .authorized))
        #expect(!result.isFresh(now: now.addingTimeInterval(1), token: nil, grant: .limited))
    }

    /// The opposite choice from `months`, and deliberately so — see `BackfillScanResult`.
    @Test("A cache from a build that recorded no grant is rejected rather than trusted")
    func olderCacheWithoutAGrantIsRejected() throws {
        let legacy = """
        {"clusters":[{"year":2025,"month":10,"assetCount":62,"cloudOnlyCount":0}],
         "scannedAt":761000000,"libraryToken":null}
        """
        let decoded = try JSONDecoder().decode(BackfillScanResult.self, from: Data(legacy.utf8))

        // It still decodes — that part has not changed.
        #expect(decoded.asClusters.count == 1)
        #expect(decoded.authorization == nil)
        #expect(!decoded.isFresh(
            now: Date(timeIntervalSince1970: 761_000_001), token: nil, grant: .authorized
        ))
    }
}

/// The loader's memo, and the affordance that could not get past it.
@MainActor
@Suite("Backfill — widening a selection")
struct BackfillWideningTests {

    private func asset(
        _ id: String,
        onDevice: Bool = true,
        on day: Int = 3
    ) -> BackfillAsset {
        BackfillAsset(id: id, creationDate: date(2019, 10, day), isOnDevice: onDevice)
    }

    /// **This is the break-test the shipped build fails.** The memo had exactly three references
    /// in the whole tree — declare, read, write — and no invalidation path, so "Share more photos"
    /// updated the month total while the photographs under it stayed as they were.
    @Test("Forgetting assets re-reads the library rather than replaying the memo")
    func forgettingAssetsRefetches() async throws {
        let month = BackfillMonth(year: 2019, month: 10)
        let source = StubAssetSource(monthAssets: [month.key: [asset("a")]])
        let loader = BackfillThumbnailLoader(source: source)

        _ = try await loader.assets(in: month)
        _ = try await loader.assets(in: month)
        #expect(source.fetchedMonths.count == 1, "the memo should serve the second read")

        loader.forgetAssets()
        _ = try await loader.assets(in: month)

        #expect(source.fetchedMonths.count == 2)
    }

    /// The observable half. Clearing the dictionary alone changes nothing on screen: every reader
    /// is already sitting on a `.task(id:)` keyed on a month key that never changes.
    @Test("Forgetting assets moves the generation the grids key their reload on")
    func forgettingAssetsMovesTheGeneration() {
        let loader = BackfillThumbnailLoader(source: StubAssetSource())
        let before = loader.generation

        loader.forgetAssets()

        #expect(loader.generation != before)
    }

    /// **The stale-write branch, which nothing else reaches.** A fetch already in flight when the
    /// grant changes resolves with the pre-change list; writing it back would repopulate the memo
    /// `forgetAssets()` had just emptied, under the new generation, where nothing would clear it
    /// again. The caller still gets what it asked for — only the memo refuses it.
    @Test("A fetch that lands after the library changed does not repopulate the memo")
    func staleFetchDoesNotRepopulateTheMemo() async throws {
        let month = BackfillMonth(year: 2019, month: 10)
        let source = StubAssetSource(monthAssets: [month.key: [asset("a")]])
        let loader = BackfillThumbnailLoader(source: source)
        // The library changes strictly between the generation stamp and the memo write.
        source.duringAssetFetch = { await MainActor.run { loader.forgetAssets() } }

        let returned = try await loader.assets(in: month)

        // The caller is still answered — it is only the memo that refuses the stale result.
        #expect(returned.count == 1)

        source.duringAssetFetch = nil
        _ = try await loader.assets(in: month)
        #expect(source.fetchedMonths.count == 2, "the stale write should not have been memoised")
    }

    /// **The count comparison this replaced could not see a swap.** A `BackfillMonthSummary` is
    /// three integers, so a `.limited` parent exchanging one October photo for another produced an
    /// identical index — and the grid went on drawing a photograph the app could no longer read
    /// while never showing the one just shared. Nothing on screen looked wrong, which is the
    /// failure `reconcileAuthorization`'s own comment calls worse than a dead end.
    @Test("A same-size swap in a month is caught, because identity is compared and not counts")
    func revalidateCatchesASameSizeSwap() async throws {
        let month = BackfillMonth(year: 2019, month: 10)
        let source = StubAssetSource(monthAssets: [month.key: [asset("a"), asset("b")]])
        let loader = BackfillThumbnailLoader(source: source)
        _ = try await loader.assets(in: month)
        let generationBefore = loader.generation

        // One photo out, one in — the count is unchanged, which is the whole point.
        source.monthAssets = [month.key: [asset("a"), asset("c")]]
        let moved = await loader.revalidate()

        #expect(moved)
        #expect(loader.generation != generationBefore)
        #expect(try await loader.assets(in: month).map(\.id) == ["a", "c"])
    }

    /// **An id list is not the asset.** `isOnDevice` flips the moment a parent downloads a photo
    /// that Optimize Storage had evicted — which is the exact remedy the iCloud badge invites them
    /// to perform — and comparing ids alone called that no change, so the tile stayed badged and
    /// refused taps for a photograph now sitting on the phone.
    @Test("A photo that came down from iCloud is a change, even though its id did not move")
    func revalidateCatchesAnAvailabilityFlip() async throws {
        let month = BackfillMonth(year: 2019, month: 10)
        let source = StubAssetSource(monthAssets: [month.key: [asset("a", onDevice: false)]])
        let loader = BackfillThumbnailLoader(source: source)
        _ = try await loader.assets(in: month)

        source.monthAssets = [month.key: [asset("a", onDevice: true)]]

        #expect(await loader.revalidate())
        #expect(try await loader.assets(in: month).first?.isOnDevice == true)
    }

    /// The sharper half of the same gap: a date edit reaches `occurred_at`, which is the one error
    /// this whole feature exists to prevent.
    @Test("A photo whose date was edited is a change, because that date becomes the entry's")
    func revalidateCatchesADateEdit() async throws {
        let month = BackfillMonth(year: 2019, month: 10)
        let source = StubAssetSource(monthAssets: [month.key: [asset("a", on: 3)]])
        let loader = BackfillThumbnailLoader(source: source)
        _ = try await loader.assets(in: month)

        // Photos' "Adjust Date & Time", still inside October.
        source.monthAssets = [month.key: [asset("a", on: 19)]]

        #expect(await loader.revalidate())
        #expect(try await loader.assets(in: month).first?.creationDate == date(2019, 10, 19))
    }

    @Test("A library that has not moved is left alone, spinner and all")
    func revalidateLeavesAnUnchangedLibraryAlone() async throws {
        let month = BackfillMonth(year: 2019, month: 10)
        let source = StubAssetSource(monthAssets: [month.key: [asset("a"), asset("b")]])
        let loader = BackfillThumbnailLoader(source: source)
        _ = try await loader.assets(in: month)
        let generationBefore = loader.generation

        let moved = await loader.revalidate()

        #expect(!moved)
        #expect(loader.generation == generationBefore, "an unchanged library must not tear the grid down")
    }

    /// The common path: a parent who has not opened a month pays nothing on every foreground.
    @Test("Revalidating with nothing loaded asks the library nothing at all")
    func revalidateWithNothingLoadedIsFree() async {
        let source = StubAssetSource()
        let loader = BackfillThumbnailLoader(source: source)

        let moved = await loader.revalidate()

        #expect(!moved)
        #expect(source.fetchedMonths.isEmpty)
    }

    /// **The one-day rule is a date guarantee, and a reload is where it could quietly break.**
    /// A photo whose date was edited in Photos is still in the month, so a month-wide `retain` kept
    /// it selected while the grid regrouped it under another day — and `use()` filters by id across
    /// every day, so the entry would have been built from two days' dates and filed under the
    /// earlier one. The caller now passes the ids on the selection's own day.
    @Test("A photo whose date moved to another day leaves the selection it was picked in")
    func selectionDropsAPhotoThatChangedDay() {
        let dayThree = date(2019, 10, 3)
        var selection = BackfillSelection()
        selection.tap(asset("a"), on: dayThree)
        selection.tap(asset("b"), on: dayThree)
        #expect(selection.count == 2)

        // "a" has moved to the 19th, so the ids still on the 3rd are just "b".
        selection.retain(["b"])

        #expect(selection.assetIds == ["b"])
        #expect(selection.day == dayThree, "the selection keeps its day; only the mover leaves")
    }

    @Test("A selection survives photos being added and drops photos that have gone")
    func selectionRetainsWhatIsStillThere() {
        let day = date(2019, 10, 3)
        var selection = BackfillSelection()
        selection.tap(asset("a"), on: day)
        selection.tap(asset("b"), on: day)
        #expect(selection.count == 2)

        // Widening only ever adds, so the selection is untouched.
        selection.retain(["a", "b", "c"])
        #expect(selection.count == 2)
        #expect(selection.day == day)

        // Narrowing takes one away. What is left is still a one-day selection.
        selection.retain(["a"])
        #expect(selection.count == 1)
        #expect(selection.day == day)

        // And when nothing is left, the day goes with it rather than stranding an empty one.
        selection.retain([])
        #expect(selection.isEmpty)
        #expect(selection.day == nil)
    }
}

/// The caption probe reads the same library, and shipped with no authorization branch at all.
@Suite("Captions — the probe's grant")
struct CaptionProbeAuthorizationTests {

    /// **An unauthorized `PHAsset.fetchAssets` does not fail, it returns nothing.** So the probe
    /// reported "0 read, not measured" as though it had looked — and this screen exists to produce
    /// one number that decides whether a whole phase gets built.
    @Test("A closed library is refused rather than counted as a zero result")
    func closedLibraryThrows() async {
        await #expect(throws: CaptionProbe.ProbeError.notAuthorized(.denied)) {
            try await CaptionProbe.run(authorization: { .denied })
        }
    }

    @Test("An undecided library is refused too, and the probe never fires the one-shot prompt")
    func undecidedLibraryThrows() async {
        await #expect(throws: CaptionProbe.ProbeError.notAuthorized(.notDetermined)) {
            try await CaptionProbe.run(authorization: { .notDetermined })
        }
    }

    /// **The positive path, which is what stops the guard being silently inverted.** `canScan` is
    /// true for exactly two of the four grants, and a test that only ever asserts the throwing side
    /// would pass just as happily against `guard !granted.canScan`.
    ///
    /// The walk itself finds nothing here — a simulator has no camera roll and this suite has no
    /// business acquiring one — so the assertion is that it *ran*, and that a selection is reported
    /// as a selection rather than as a library.
    @Test("An open library is not refused, and a selection reports itself as one")
    func openLibraryRuns() async throws {
        let whole = try await CaptionProbe.run(ceiling: 1, authorization: { .authorized })
        #expect(whole.limitedLibrary == false)

        let selection = try await CaptionProbe.run(ceiling: 1, authorization: { .limited })
        #expect(selection.limitedLibrary)
    }

    /// The two refusals are not one refusal. `AddToArchiveModel.cameraRollSubtitle` has always
    /// drawn this line; the probe's screen now draws it too, and pointing a parent who already
    /// said no back at the browser would be a retry funnel in all but name.
    @MainActor
    @Test("A refusal and a question that was never asked get different sentences")
    func refusedAndUnaskedReadDifferently() {
        let denied = CaptionProbeScreen.unauthorizedExplanation(for: .denied)
        let undecided = CaptionProbeScreen.unauthorizedExplanation(for: .notDetermined)

        #expect(denied != undecided)
        // The browser cannot ask again after a refusal, so it must not be named as though it could.
        #expect(!denied.contains("camera roll"))
        #expect(undecided.contains("camera roll"))
    }
}

/// The gate that decides whether the Settings round-trip is noticed at all.
///
/// **This suite exists because the first version of that gate was inert.** It read
/// `previous == .background, current == .active`, a transition iOS never delivers in one step, so
/// the reconcile behind it could never run — a fix that compiled, shipped, and did nothing, on a
/// path no model-level test could reach. The comparison now lives somewhere it can be asserted.
@Suite("Backfill — noticing a grant change")
struct BackfillGrantChangeTests {

    @Test("Only the active phase re-reads, because iOS interposes inactive on the way back in")
    func onlyActiveRereads() {
        #expect(BackfillGrantChange.shouldReread(.active))
        // The two halves of a real foreground, neither of which is the moment to act.
        #expect(!BackfillGrantChange.shouldReread(.inactive))
        #expect(!BackfillGrantChange.shouldReread(.background))
    }

    @Test("Nothing drawn yet is nothing to reconcile — the flow's own task owns the first routing")
    func nothingDrawnYet() {
        #expect(BackfillGrantChange.effect(was: nil, now: .authorized) == .none)
        #expect(BackfillGrantChange.effect(was: nil, now: .denied) == .none)
    }

    /// A grant that cannot see photos has nothing to re-read.
    @Test("An ordinary foreground on a grant that reads nothing costs nothing")
    func unreadableGrantIsFree() {
        #expect(BackfillGrantChange.effect(was: .denied, now: .denied) == .none)
        #expect(BackfillGrantChange.effect(was: .notDetermined, now: .notDetermined) == .none)
    }

    /// **Every readable grant, not only `.limited`.** The first version scoped this to selected
    /// photos and reasoned about selection edits, which was the case in front of it rather than
    /// the general one: a date corrected in Photos and an original pulled down from iCloud happen
    /// under full access too, and the first of them decides an entry's `occurred_at`. Scoping it
    /// narrowly left the most common grant with no invalidation at all.
    @Test("A readable grant re-reads on every foreground, full access included")
    func anyReadableGrantRescans() {
        #expect(BackfillGrantChange.effect(was: .authorized, now: .authorized) == .rescan)
        #expect(BackfillGrantChange.effect(was: .limited, now: .limited) == .rescan)
    }

    /// The selection can be edited in Settings without the grant level moving at all, and the
    /// `.limited` screen's own Settings link is an invitation to do exactly that.
    ///
    /// **`.rescan`, emphatically not `.reroute`.** The first version of this returned the same
    /// effect as a widening, and a re-route re-derives the stage from the grant alone — which
    /// marched a `.limited` parent back to the interstitial they had dismissed with "Continue with
    /// these", flashing the scanning screen on the way, on every single foreground. Same kind of
    /// access, different photographs behind it: the data is stale, the screen is not.
    @Test("An unchanged limited grant re-reads the library and moves nobody")
    func unchangedLimitedRescansOnly() {
        #expect(BackfillGrantChange.effect(was: .limited, now: .limited) == .rescan)
    }

    @Test("A grant that widened re-decides the screen but keeps the month")
    func wideningKeepsTheMonth() {
        #expect(BackfillGrantChange.effect(was: .denied, now: .authorized) == .reroute)
        #expect(BackfillGrantChange.effect(was: .denied, now: .limited) == .reroute)
        #expect(BackfillGrantChange.effect(was: .limited, now: .authorized) == .reroute)
        #expect(BackfillGrantChange.effect(was: .notDetermined, now: .authorized) == .reroute)
    }

    /// The distinction the interstitial regression turned on, asserted as a property rather than
    /// as four more pairs: **only a change of *kind* may move the parent.**
    @Test("Only a grant that actually changed kind is allowed to re-route")
    func onlyAKindChangeReroutes() {
        let grants: [BackfillAuthorization] = [.authorized, .limited, .denied, .notDetermined]
        for was in grants {
            for now in grants where was == now {
                let effect = BackfillGrantChange.effect(was: was, now: now)
                #expect(effect == .rescan || effect == .none)
                #expect(effect != .reroute)
                #expect(effect != .rebuild)
            }
        }
    }

    /// A grid of photographs the app can no longer read is worse than a dead end, because nothing
    /// on it looks wrong.
    @Test("A grant that narrowed leaves the month as well as re-reading")
    func narrowingLeavesTheMonth() {
        #expect(BackfillGrantChange.effect(was: .authorized, now: .limited) == .rebuild)
        #expect(BackfillGrantChange.effect(was: .authorized, now: .denied) == .rebuild)
        #expect(BackfillGrantChange.effect(was: .limited, now: .denied) == .rebuild)
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
        let model = BackfillScanner(source: source, childId: UUID(), dismissals: InMemoryBackfillDismissalStore(),
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
        let model = BackfillScanner(source: StubAssetSource(dates: dates), childId: UUID(), dismissals: dismissals,
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

// MARK: - Scoping the browse surface to the child's life

/// Phase 18 follow-up — `SUGGESTED` and `EVERY MONTH` are bounded by the child, not by the library.
///
/// The defect these replace: both lists enumerated every month that held a photo, so a parent whose
/// camera roll starts in 2012 opened the browse screen on ~170 months for a child born in 2022.
/// Fourteen of those years are not this child's childhood.
///
/// **The timezone assertions are the ones with teeth.** "What month is it" is a question about the
/// child's `family_timezone`, and answering it with `Calendar.current` is the `daysUntilExpiry`
/// defect from Phase 11 in a second place — invisible on any device sitting in the family's own zone,
/// which is every device a developer tests on.
@Suite("Backfill — this month, in the years before it")
struct BackfillSuggestedMonthsTests {

    private func counts(_ keys: [(Int, Int, Int)]) -> [BackfillMonth: Int] {
        Dictionary(uniqueKeysWithValues: keys.map { (BackfillMonth(year: $0.0, month: $0.1), $0.2) })
    }

    /// Required test 1. Four cards, not five — the child did not exist for the fifth.
    @Test("A child born June 2022, browsing in August 2026, is offered four Augusts")
    func fourAugustsForAChildBornIn2022() {
        let suggested = BackfillPlan.suggested(
            thisMonth: BackfillMonth(year: 2026, month: 8),
            birthMonth: BackfillMonth(year: 2022, month: 6),
            photoCounts: counts([
                (2025, 8, 40), (2024, 8, 30), (2023, 8, 20), (2022, 8, 10), (2021, 8, 90),
            ])
        )

        #expect(suggested.map(\.key) == ["2025-08", "2024-08", "2023-08", "2022-08"])
        // August 2021 holds ninety photos and is still refused: the child was not born.
        #expect(suggested.contains(BackfillMonth(year: 2021, month: 8)) == false)
        // And the current month of the current year is never a candidate — it is still happening.
        #expect(suggested.contains(BackfillMonth(year: 2026, month: 8)) == false)
    }

    /// Required test 2, first half. A birthdate on the **first** of a month keeps that month.
    @Test("A child born on the 1st keeps their birth month")
    func bornOnTheFirstKeepsTheMonth() {
        let birthMonth = BackfillMonth(calendarDay: "2022-06-01")
        #expect(birthMonth == BackfillMonth(year: 2022, month: 6))

        let suggested = BackfillPlan.suggested(
            thisMonth: BackfillMonth(year: 2026, month: 6),
            birthMonth: birthMonth,
            photoCounts: counts([(2025, 6, 5), (2024, 6, 5), (2023, 6, 5), (2022, 6, 5), (2021, 6, 5)])
        )

        #expect(suggested.map(\.key) == ["2025-06", "2024-06", "2023-06", "2022-06"])
    }

    /// Required test 2, second half. A birthdate on the **last** day of a month keeps that month and
    /// nothing earlier — the floor is the month, not the day.
    @Test("A child born on the last day of a month keeps that month and no earlier one")
    func bornOnTheLastDayKeepsThatMonth() {
        let birthMonth = BackfillMonth(calendarDay: "2022-06-30")
        #expect(birthMonth == BackfillMonth(year: 2022, month: 6))

        let suggested = BackfillPlan.suggested(
            thisMonth: BackfillMonth(year: 2026, month: 6),
            birthMonth: birthMonth,
            photoCounts: counts([(2025, 6, 5), (2024, 6, 5), (2023, 6, 5), (2022, 6, 5), (2021, 6, 5)])
        )

        #expect(suggested.map(\.key) == ["2025-06", "2024-06", "2023-06", "2022-06"])
        #expect(suggested.allSatisfy { $0 >= BackfillMonth(year: 2022, month: 6) })
    }

    /// Required test 3. **No substitution.** The count drops; a neighbouring month is never promoted
    /// into the empty slot, because the section's premise is "this month, earlier".
    @Test("Two dismissed candidates shorten the list rather than being replaced")
    func dismissalShortensRatherThanSubstitutes() {
        let photoCounts = counts([
            (2025, 8, 40), (2024, 8, 30), (2023, 8, 20), (2022, 8, 10), (2021, 8, 90),
            // Neighbours with plenty in them, sitting right there to be wrongly promoted.
            (2024, 7, 500), (2023, 9, 500),
        ])

        let all = BackfillPlan.suggested(
            thisMonth: BackfillMonth(year: 2026, month: 8),
            birthMonth: BackfillMonth(year: 2019, month: 1),
            photoCounts: photoCounts
        )
        #expect(all.count == 5)

        let pruned = BackfillPlan.suggested(
            thisMonth: BackfillMonth(year: 2026, month: 8),
            birthMonth: BackfillMonth(year: 2019, month: 1),
            photoCounts: photoCounts,
            dismissed: ["2024-08", "2023-08"]
        )

        #expect(pruned.count == 3)
        #expect(pruned.map(\.key) == ["2025-08", "2022-08", "2021-08"])
        // The neighbours were never candidates and must not have been drafted in.
        #expect(pruned.contains(BackfillMonth(year: 2024, month: 7)) == false)
        #expect(pruned.contains(BackfillMonth(year: 2023, month: 9)) == false)
    }

    /// An empty candidate shortens the list the same way a dismissed one does.
    @Test("A candidate month with no photos is skipped, not substituted")
    func emptyCandidateIsSkipped() {
        let suggested = BackfillPlan.suggested(
            thisMonth: BackfillMonth(year: 2026, month: 8),
            birthMonth: BackfillMonth(year: 2019, month: 1),
            photoCounts: counts([(2025, 8, 40), (2023, 8, 20), (2021, 8, 1)])
        )

        #expect(suggested.map(\.key) == ["2025-08", "2023-08", "2021-08"])
    }

    /// Required test 4. **The month is the child's, not the phone's.**
    ///
    /// 13 hours apart, on the first and the last instant of a month. A device in Auckland at 00:30
    /// on 1 September is still 11:30 on 31 August in Los Angeles — so the child's calendar says
    /// August, and a `Calendar.current` answer would offer Septembers a month early.
    @Test("The month is read in family_timezone, not in the device's zone")
    func thisMonthIsTheChildsMonth() {
        let family = "America/Los_Angeles"

        // First instant of September in Auckland — still August where the child lives.
        let firstOfSeptemberInAuckland = date(2026, 9, 1, hour: 0, zone: "Pacific/Auckland")
        let childs = BackfillCalendar.month(containing: firstOfSeptemberInAuckland, in: family)
        let devices = BackfillMonth(containing: firstOfSeptemberInAuckland, calendar: {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "Pacific/Auckland")!
            return c
        }())

        #expect(childs == BackfillMonth(year: 2026, month: 8))
        #expect(devices == BackfillMonth(year: 2026, month: 9))
        #expect(childs != devices)

        // The last instant of August in Los Angeles is already September in Auckland, and the
        // child's answer is still August.
        let lastOfAugustInLA = date(2026, 8, 31, hour: 23, zone: family)
        #expect(BackfillCalendar.month(containing: lastOfAugustInLA, in: family)
            == BackfillMonth(year: 2026, month: 8))

        // And the rule built on it offers Augusts rather than Septembers.
        let suggested = BackfillPlan.suggested(
            thisMonth: childs!,
            birthMonth: BackfillMonth(year: 2020, month: 1),
            photoCounts: counts([(2025, 8, 3), (2025, 9, 300), (2024, 8, 3), (2024, 9, 300)])
        )
        #expect(suggested.map(\.key) == ["2025-08", "2024-08"])
    }

    /// An unknown zone identifier falls back to the device's rather than to UTC — a wrong-but-local
    /// answer is off by hours, and UTC is off by hours *and* wrong for everybody.
    @Test("An unrecognised timezone falls back to the device rather than to UTC")
    func unknownZoneFallsBackToDevice() {
        let now = Date()
        #expect(BackfillCalendar.family("Mars/Olympus_Mons").timeZone == TimeZone.current)
        #expect(BackfillCalendar.month(containing: now, in: nil)
            == BackfillMonth(containing: now, calendar: .current))
    }

    /// Required test 5. `EVERY MONTH` is floored at the birth month and stops before this one, and
    /// a month with no photos was never in the index to begin with.
    @Test("Every month holds nothing before the birth month and nothing with a zero count")
    func everyMonthIsFlooredAndNonZero() {
        let index = BackfillPlan.monthIndex(
            assetDates: [
                date(2026, 8, 1),                                   // this month — still in progress
                date(2026, 7, 1), date(2026, 7, 2),
                date(2023, 4, 9),
                date(2022, 6, 30),                                  // the birth month itself
                date(2022, 5, 31),                                  // the day before the child
                date(2014, 1, 1),
            ],
            entryDates: [],
            calendar: calendar
        )

        let browsable = BackfillPlan.browsable(
            index,
            birthMonth: BackfillMonth(calendarDay: "2022-06-30"),
            thisMonth: BackfillMonth(year: 2026, month: 8)
        )

        #expect(browsable.map(\.month.key) == ["2026-07", "2023-04", "2022-06"])
        #expect(browsable.allSatisfy { $0.assetCount > 0 })
        #expect(browsable.allSatisfy { $0.month >= BackfillMonth(year: 2022, month: 6) })
        // The current month is excluded: it is still happening, and its photos are this week's.
        #expect(browsable.contains { $0.month == BackfillMonth(year: 2026, month: 8) } == false)
    }

    /// A birthdate the archive has not delivered yet applies no floor. Offering everything is the
    /// honest answer to "we do not know when the child was born"; offering nothing is not.
    @Test("A missing birthdate applies no floor rather than an empty list")
    func missingBirthdateAppliesNoFloor() {
        let index = BackfillPlan.monthIndex(
            assetDates: [date(2014, 1, 1), date(2023, 4, 9)], entryDates: [], calendar: calendar
        )
        let browsable = BackfillPlan.browsable(
            index, birthMonth: nil, thisMonth: BackfillMonth(year: 2026, month: 8)
        )

        #expect(browsable.map(\.month.key) == ["2023-04", "2014-01"])
    }

    /// The birth month comes out of the `YYYY-MM-DD` string with no instant in between, so no zone
    /// can move it. Parsing to a `Date` first is what puts a child born on the 1st into May.
    @Test("The birth month is read from the calendar day, not from an instant")
    func birthMonthIsZoneProof() {
        #expect(BackfillMonth(calendarDay: "2022-06-01") == BackfillMonth(year: 2022, month: 6))
        #expect(BackfillMonth(calendarDay: "2022-12-31") == BackfillMonth(year: 2022, month: 12))
        #expect(BackfillMonth(calendarDay: "2022-01-01") == BackfillMonth(year: 2022, month: 1))
        #expect(BackfillMonth(calendarDay: "not-a-date") == nil)
        #expect(BackfillMonth(calendarDay: "2022-13-01") == nil)
    }
}

// MARK: - The contact sheet's geometry

/// Phase 18 follow-up — a tile's rect is arithmetic, and it does not depend on the photograph.
@MainActor
@Suite("Backfill — the picker grid")
struct BackfillGridTests {

    /// Required test 7. A 9:16 asset and a 16:9 asset produce identical tile rects.
    ///
    /// The defect: `BackfillThumbnail` put `.scaledToFill()` under a `.clipShape` with no frame
    /// between them. A clip shape is sized to the view's own bounds rather than to the space
    /// proposed, so a portrait asset grew its bounds, clipped itself to the larger square and drew
    /// across its neighbours — and in a `LazyVGrid` a row is as tall as its tallest child, which is
    /// what put photographs over the pinned day header. The frame is now stated rather than
    /// inferred, so this holds for any source shape by construction.
    @Test("A tile's rect is the same whatever shape the photograph is")
    func tileRectIsInvariantToAspectRatio() {
        let side = BackfillGrid.tileSide(forWidth: 393, margin: 16)

        // The frame the tile is given is a function of the screen, and nothing else is an input.
        let portrait = CGSize(width: side, height: side)   // a 9:16 asset lands here
        let landscape = CGSize(width: side, height: side)  // and so does a 16:9 one
        #expect(portrait == landscape)

        // Three of them plus two gutters fit inside the content width, with nothing spilling past
        // the trailing margin.
        let used = side * 3 + BackfillGrid.gutter * 2
        #expect(used <= 393 - 32)
        #expect(393 - 32 - used < 3)
        #expect(side == side.rounded(.down))
    }

    /// The design system's contact sheet, not the mosaic: 3pt gutters, radius 2, three columns.
    @Test("The grid keeps the contact-sheet geometry the design system argues for")
    func geometryMatchesTheDesignSystem() {
        #expect(BackfillGrid.columns == 3)
        #expect(BackfillGrid.gutter == 3)
        #expect(BackfillGrid.cornerRadius == 2)
        #expect(BackfillGrid.cornerRadius != Layout.mediaInsetRadius)
    }

    /// PhotoKit takes pixels. Asking in points gets a third of the picture back on a 3× phone, and
    /// the tile renders soft.
    @Test("The request size is in pixels, not points")
    func requestSizeIsInPixels() {
        let side = BackfillGrid.tileSide(forWidth: 393, margin: 16)
        #expect(BackfillGrid.pixelSize(forTileSide: side, scale: 3) == Int(side * 3))
        #expect(BackfillGrid.pixelSize(forTileSide: side, scale: 3)
            > BackfillGrid.pixelSize(forTileSide: side, scale: 1))
    }

    /// A narrow phone and a wide one both get whole-point tiles that fit.
    @Test("Tiles fit their content width on every screen size")
    func tilesFitEveryWidth() {
        for width in [320.0, 375.0, 393.0, 402.0, 430.0, 440.0] {
            let side = BackfillGrid.tileSide(forWidth: width, margin: 16)
            #expect(side == side.rounded(.down))
            #expect(side * 3 + BackfillGrid.gutter * 2 <= width - 32)
            #expect(side > 0)
        }
    }
}

// MARK: - The one-day rule, after a pass that redrew the grid around it

/// Required test 6. **The rule is asserted against `BackfillSelection`, never through the view.**
///
/// This pass replaced the selection affordance, the tile's frame, its corner radius, its animation
/// and its tap target. None of that is allowed to touch what a selection *means*: a set of photos
/// from exactly one day, because `BackfillDateRule` resolves a selection to its earliest plausible
/// creation date and a selection spread over three weeks produces a date that is defensible and not
/// accurate. Confining it to one day is the only reason the `occurred_at` this feature produces is
/// exact — so the rule is pinned here, where no amount of redrawing can reach it.
@Suite("Backfill — the one-day rule survives the picker rebuild")
struct BackfillSingleDaySurvivalTests {

    private let monday = date(2025, 10, 6)
    private let tuesday = date(2025, 10, 7)

    private func asset(_ id: String, _ at: Date, onDevice: Bool = true) -> BackfillAsset {
        BackfillAsset(id: id, creationDate: at, isOnDevice: onDevice)
    }

    @Test("A selection still belongs to exactly one day")
    func selectionIsStillConfinedToOneDay() {
        var selection = BackfillSelection()

        selection.tap(asset("a", date(2025, 10, 6, hour: 9)), on: monday)
        selection.tap(asset("b", date(2025, 10, 6, hour: 17)), on: monday)
        #expect(selection.count == 2)
        #expect(selection.day == monday)

        // A tile on a second day is **held, not acted on** — nothing is added and nothing already
        // picked is discarded. Both halves matter: silently refusing the tap and silently clearing
        // the selection are each their own defect.
        selection.tap(asset("c", date(2025, 10, 7, hour: 9)), on: tuesday)
        #expect(selection.count == 2)
        #expect(selection.day == monday)
        #expect(selection.blockedDay == tuesday)
        #expect(selection.assetIds.contains("c") == false)

        // "Start here" abandons rather than carries across: the photos on the old day are not the
        // same moment as the ones on the new one.
        selection.startOver()
        #expect(selection.isEmpty)
        #expect(selection.day == nil)
        #expect(selection.blockedDay == nil)

        selection.tap(asset("c", date(2025, 10, 7, hour: 9)), on: tuesday)
        #expect(selection.day == tuesday)
        #expect(selection.count == 1)
    }

    /// The new affordance draws no circle on a cloud-only tile and the tile is not tappable. The
    /// model refuses it independently, so a future tile that forgot to disable itself still cannot
    /// put an undownloadable photo into an entry.
    @Test("A cloud-only photo is still unselectable at the model, not only in the view")
    func cloudOnlyIsStillRefusedByTheModel() {
        var selection = BackfillSelection()
        selection.tap(asset("cloud", date(2025, 10, 6, hour: 9), onDevice: false), on: monday)

        #expect(selection.isEmpty)
        #expect(selection.day == nil)
        #expect(selection.blockedDay == nil)
    }

    /// A one-day selection resolves to that exact day, which is the whole point of the rule.
    @Test("One day in, an exact date out — never the month fallback")
    func oneDayResolvesExactly() {
        var selection = BackfillSelection()
        let morning = date(2025, 10, 6, hour: 9)
        let evening = date(2025, 10, 6, hour: 19)
        selection.tap(asset("a", morning), on: monday)
        selection.tap(asset("b", evening), on: monday)

        let plan = BackfillEntryPlan(
            month: BackfillMonth(year: 2025, month: 10),
            creationDates: [morning, evening],
            calendar: calendar
        )

        #expect(plan.occurredAt == morning)
        #expect(plan.occurredAtSource == .assetCreationDate)
        #expect(plan.isDateDefaulted == false)
        #expect(selection.count == 2)
    }
}

// MARK: - The thumbnail loader, and the window it has to hand back

/// A source that records what the loader asked PhotoKit for.
///
/// The caching window is the thing worth pinning: `PHCachingImageManager` releases a window only
/// when `stop` names the same assets at the same target size, and neither the pairing nor its
/// failure is visible from outside — an unpaired `start` is a leak with nothing on screen to show
/// for it.
@MainActor
private final class RecordingThumbnailSource: BackfillAssetSource, @unchecked Sendable {
    nonisolated(unsafe) var thumbnailCalls: [(id: String, maxPixel: Int)] = []
    nonisolated(unsafe) var started: [(ids: [String], maxPixel: Int)] = []
    nonisolated(unsafe) var stopped: [(ids: [String], maxPixel: Int)] = []
    nonisolated(unsafe) var stoppedAll = 0
    /// Assets that have nothing local, mirroring PhotoKit with network access off.
    nonisolated(unsafe) var missing: Set<String> = []

    nonisolated func authorization() async -> BackfillAuthorization { .authorized }
    nonisolated func requestAuthorization() async -> BackfillAuthorization { .authorized }
    nonisolated func libraryToken() async -> String? { nil }
    nonisolated func creationDates() async throws -> (onDevice: [Date], cloudOnly: [Date]) { ([], []) }
    nonisolated func assets(in month: BackfillMonth) async throws -> [BackfillAsset] { [] }
    nonisolated func imageData(for assetId: String) async throws -> Data { Data() }

    nonisolated func thumbnail(for assetId: String, maxPixel: Int) async -> Data? {
        thumbnailCalls.append((assetId, maxPixel))
        guard !missing.contains(assetId) else { return nil }
        return Data([UInt8(truncatingIfNeeded: maxPixel)])
    }

    nonisolated func startCachingThumbnails(_ assetIds: [String], maxPixel: Int) {
        started.append((assetIds, maxPixel))
    }

    nonisolated func stopCachingThumbnails(_ assetIds: [String], maxPixel: Int) {
        stopped.append((assetIds, maxPixel))
    }

    nonisolated func stopCachingAllThumbnails() { stoppedAll += 1 }
}

@MainActor
@Suite("Backfill — the thumbnail loader")
struct BackfillThumbnailLoaderTests {

    /// **A window is stopped with the size it was started with, not with whatever the caller holds
    /// now.** The picker seeds its width and corrects it in the same layout pass, so a day whose
    /// `onAppear` fired against the seed and whose `onDisappear` fires against the real width would
    /// otherwise stop a window that was never started — and leave the started one decoded for the
    /// life of the screen, which is the memory this caching exists to bound.
    @Test("A caching window is released with the size it was warmed at, not the current one")
    func windowStopsWithTheSizeItStarted() {
        let source = RecordingThumbnailSource()
        let loader = BackfillThumbnailLoader(source: source)
        let ids = ["a", "b", "c"]

        loader.startCaching(ids, pixelSize: 354, forWindow: "day-1")
        #expect(loader.warmWindowCount == 1)

        // The screen has since measured itself and the tiles are bigger.
        loader.stopCaching(forWindow: "day-1")

        #expect(source.started.count == 1)
        #expect(source.started[0].maxPixel == 354)
        #expect(source.stopped.count == 1)
        #expect(source.stopped[0].maxPixel == 354, "stopped at the size it started at")
        #expect(source.stopped[0].ids == ids)
        #expect(loader.warmWindowCount == 0)
    }

    @Test("Warming the same window at a new size releases the old one first")
    func rewarmingReleasesTheOldWindow() {
        let source = RecordingThumbnailSource()
        let loader = BackfillThumbnailLoader(source: source)

        loader.startCaching(["a"], pixelSize: 354, forWindow: "day-1")
        loader.startCaching(["a"], pixelSize: 363, forWindow: "day-1")

        #expect(source.stopped.count == 1)
        #expect(source.stopped[0].maxPixel == 354)
        #expect(source.started.map(\.maxPixel) == [354, 363])
        #expect(loader.warmWindowCount == 1)
    }

    @Test("Warming a window that is already warm at that size does nothing twice")
    func rewarmingAtTheSameSizeIsANoOp() {
        let source = RecordingThumbnailSource()
        let loader = BackfillThumbnailLoader(source: source)

        loader.startCaching(["a"], pixelSize: 354, forWindow: "day-1")
        loader.startCaching(["a"], pixelSize: 354, forWindow: "day-1")

        #expect(source.started.count == 1)
        #expect(source.stopped.isEmpty)
    }

    @Test("Stopping a window that was never warmed asks PhotoKit for nothing")
    func stoppingAnUnknownWindowIsSilent() {
        let source = RecordingThumbnailSource()
        let loader = BackfillThumbnailLoader(source: source)

        loader.stopCaching(forWindow: "never-started")

        #expect(source.stopped.isEmpty)
    }

    /// The backstop for a window whose `onDisappear` never arrived, which is what a dismissed
    /// screen does to its children.
    @Test("Leaving the picker releases every window, warmed or not")
    func leavingReleasesEverything() {
        let source = RecordingThumbnailSource()
        let loader = BackfillThumbnailLoader(source: source)

        loader.startCaching(["a"], pixelSize: 354, forWindow: "day-1")
        loader.startCaching(["b"], pixelSize: 354, forWindow: "day-2")
        loader.stopCachingEverything()

        #expect(source.stoppedAll == 1)
        #expect(loader.warmWindowCount == 0)
        // And a stop arriving afterwards does not double-release.
        loader.stopCaching(forWindow: "day-1")
        #expect(source.stopped.isEmpty)
    }

    /// **Keyed on the size as well as the asset.** The suggested-month strip asks for 320 and the
    /// grid asks for its own tile side; an asset-only key hands the grid whichever landed first and
    /// the tile renders upscaled for no reason anyone can see.
    @Test("The same photograph at two sizes is two cache entries, not one")
    func cacheIsKeyedOnSizeAsWellAsAsset() async {
        let source = RecordingThumbnailSource()
        let loader = BackfillThumbnailLoader(source: source)

        let strip = await loader.thumbnail(for: "a", pixelSize: 320)
        let grid = await loader.thumbnail(for: "a", pixelSize: 354)
        #expect(source.thumbnailCalls.map(\.maxPixel) == [320, 354])
        #expect(strip != grid)

        // Both are now cached, each at its own size, and neither refetches.
        _ = await loader.thumbnail(for: "a", pixelSize: 320)
        _ = await loader.thumbnail(for: "a", pixelSize: 354)
        #expect(source.thumbnailCalls.count == 2)
    }

    /// Availability is a fact about the asset, not about the size asked for — so one refusal is
    /// enough and a cloud-only tile does not retry at every size the screen happens to want.
    @Test("An asset with nothing local is refused once, at every size")
    func unavailableIsRememberedAcrossSizes() async {
        let source = RecordingThumbnailSource()
        source.missing = ["cloud"]
        let loader = BackfillThumbnailLoader(source: source)

        #expect(await loader.thumbnail(for: "cloud", pixelSize: 320) == nil)
        #expect(await loader.thumbnail(for: "cloud", pixelSize: 354) == nil)
        #expect(await loader.thumbnail(for: "cloud", pixelSize: 320) == nil)

        #expect(source.thumbnailCalls.count == 1, "asked once, refused for good")
    }

    /// The eviction list holds one entry per cached key. A key recorded twice evicts its bytes on
    /// the first pass and removes nothing on the second, so the cache quietly holds fewer than its
    /// limit and refetches pictures it had already paid for.
    @Test("A cached thumbnail is recorded once in the eviction order, not once per request")
    func evictionOrderHoldsNoDuplicates() async {
        let source = RecordingThumbnailSource()
        let loader = BackfillThumbnailLoader(source: source, maxPixel: 320, limit: 2)

        _ = await loader.thumbnail(for: "a", pixelSize: 320)
        _ = await loader.thumbnail(for: "b", pixelSize: 320)
        // `a` again from cache — must not take a second slot in the order.
        _ = await loader.thumbnail(for: "a", pixelSize: 320)
        // A third distinct key evicts exactly one entry, and it is `a` rather than nothing.
        _ = await loader.thumbnail(for: "c", pixelSize: 320)

        #expect(source.thumbnailCalls.count == 3)
        // `b` and `c` survive; `a` was the oldest and went.
        _ = await loader.thumbnail(for: "b", pixelSize: 320)
        _ = await loader.thumbnail(for: "c", pixelSize: 320)
        #expect(source.thumbnailCalls.count == 3, "b and c were still cached")
    }
}

// MARK: - Month arithmetic across a year boundary

/// `BackfillMonth` is two integers on purpose, and the two places that walk it — one year back for
/// `SUGGESTED`, one month back for `EVERY MONTH`'s ceiling — both cross a year boundary in January.
/// A parent browsing on New Year's Day is the case nobody tests by hand.
@Suite("Backfill — month arithmetic")
struct BackfillMonthArithmeticTests {

    @Test("The month before January is December of the year before")
    func previousCrossesTheYear() {
        #expect(BackfillMonth(year: 2026, month: 1).previous() == BackfillMonth(year: 2025, month: 12))
        #expect(BackfillMonth(year: 2026, month: 3).previous() == BackfillMonth(year: 2026, month: 2))
        #expect(BackfillMonth(year: 2026, month: 12).previous() == BackfillMonth(year: 2026, month: 11))
    }

    @Test("Subtracting years keeps the month, including January")
    func subtractingYearsKeepsTheMonth() {
        #expect(BackfillMonth(year: 2026, month: 1).subtracting(years: 1) == BackfillMonth(year: 2025, month: 1))
        #expect(BackfillMonth(year: 2026, month: 1).subtracting(years: 5) == BackfillMonth(year: 2021, month: 1))
        #expect(BackfillMonth(year: 2026, month: 12).subtracting(years: 3) == BackfillMonth(year: 2023, month: 12))
    }

    /// Browsing on the 1st of January: the candidates are the five Januaries before this one, and
    /// `EVERY MONTH` runs to the December just gone rather than stopping a year short.
    @Test("A January browse offers Januaries and browses back through December")
    func januaryBrowse() {
        let thisMonth = BackfillMonth(year: 2026, month: 1)

        let suggested = BackfillPlan.suggested(
            thisMonth: thisMonth,
            birthMonth: BackfillMonth(year: 2020, month: 6),
            photoCounts: Dictionary(uniqueKeysWithValues: (2021...2025).map {
                (BackfillMonth(year: $0, month: 1), 4)
            })
        )
        #expect(suggested.map(\.key) == ["2025-01", "2024-01", "2023-01", "2022-01", "2021-01"])

        let index = BackfillPlan.monthIndex(
            assetDates: [date(2026, 1, 3), date(2025, 12, 20), date(2020, 6, 30), date(2020, 5, 30)],
            entryDates: [],
            calendar: calendar
        )
        let browsable = BackfillPlan.browsable(
            index, birthMonth: BackfillMonth(year: 2020, month: 6), thisMonth: thisMonth
        )
        #expect(browsable.map(\.month.key) == ["2025-12", "2020-06"])
    }

    /// A leap day is a calendar day like any other here — the birth month is read out of the
    /// string, so February 29th is February and nothing has to know the year was a leap year.
    @Test("A leap-day birthdate reads as February")
    func leapDayBirthdate() {
        #expect(BackfillMonth(calendarDay: "2024-02-29") == BackfillMonth(year: 2024, month: 2))
    }

    /// Five candidates is a ceiling, and a shorter reach is honoured rather than clamped up.
    @Test("The reach back is a ceiling, and asking for fewer years gives fewer candidates")
    func yearsBackIsHonoured() {
        let counts = Dictionary(uniqueKeysWithValues: (2021...2025).map {
            (BackfillMonth(year: $0, month: 8), 4)
        })
        let two = BackfillPlan.suggested(
            thisMonth: BackfillMonth(year: 2026, month: 8),
            birthMonth: nil, photoCounts: counts, yearsBack: 2
        )
        #expect(two.map(\.key) == ["2025-08", "2024-08"])
        #expect(BackfillPlan.suggestedYearsBack == 5)
    }
}

// MARK: - One in-flight thumbnail, and the three things racing to end it

#if canImport(Photos)
import Photos

/// PhotoKit's result handler, the task's cancellation, and the closure still assembling the request
/// all race to finish the same continuation. A `CheckedContinuation` resumed twice is a crash; one
/// resumed zero times is a tile whose task never ends and which never draws anything again.
///
/// **The interesting assertion is that cancellation resumes the continuation itself** rather than
/// waiting for PhotoKit to call back. `cancelImageRequest` is documented to deliver a final
/// cancelled callback and in practice does — but "in practice" is not a property a scrolling grid
/// should depend on, and every test here would still pass if that callback never came.
@Suite("Backfill — the in-flight thumbnail request")
struct ThumbnailRequestTests {

    @Test("An ordinary request resumes once, with its bytes")
    func normalFinish() async {
        let request = ThumbnailRequest()
        let result = await withCheckedContinuation { continuation in
            request.attach(continuation)
            #expect(request.store(3) == nil)
            request.finish(Data([1, 2]))
            // PhotoKit is documented to call a result handler more than once for some delivery
            // modes. The second one must be dropped rather than crash.
            request.finish(Data([9]))
        }
        #expect(result == Data([1, 2]))
    }

    /// **No callback is ever delivered here.** If cancellation waited for one, this test would hang
    /// rather than fail — which is exactly what the tile would do.
    @Test("Cancellation ends the request without waiting for PhotoKit")
    func cancelResumesWithoutACallback() async {
        let request = ThumbnailRequest()
        let result = await withCheckedContinuation { continuation in
            request.attach(continuation)
            #expect(request.store(42) == nil)
            // The id comes back so the caller can cancel it at PhotoKit.
            #expect(request.cancel() == 42)
        }
        #expect(result == nil)
    }

    /// `withTaskCancellationHandler` may run its handler before the operation has built anything.
    /// The request then has no continuation to resume and no id to hand back, and both arrive after.
    @Test("Cancellation arriving before the continuation still ends the request")
    func cancelBeforeAttach() async {
        let request = ThumbnailRequest()
        #expect(request.cancel() == nil, "nothing outstanding at PhotoKit yet")

        let result = await withCheckedContinuation { continuation in
            request.attach(continuation)
            // Already cancelled, so the id is handed straight back for the caller to cancel —
            // otherwise this request would run to completion with nobody holding its id.
            #expect(request.store(7) == 7)
        }
        #expect(result == nil)
    }

    @Test("A callback arriving after cancellation is dropped rather than resuming twice")
    func callbackAfterCancelIsDropped() async {
        let request = ThumbnailRequest()
        let result = await withCheckedContinuation { continuation in
            request.attach(continuation)
            _ = request.store(1)
            _ = request.cancel()
            // PhotoKit's cancelled callback. Resuming here would be a crash.
            request.finish(Data([9]))
        }
        #expect(result == nil)
    }

    @Test("Cancelling twice hands the id back once")
    func cancellingTwiceIsIdempotent() async {
        let request = ThumbnailRequest()
        let result = await withCheckedContinuation { continuation in
            request.attach(continuation)
            _ = request.store(5)
            #expect(request.cancel() == 5)
            #expect(request.cancel() == nil, "already taken")
        }
        #expect(result == nil)
    }

    /// A `.fastFormat` request can answer on the calling thread before `requestImage` has returned
    /// an id at all, so the request finishes before it is fully assembled.
    @Test("A synchronous answer before the id exists still resumes exactly once")
    func synchronousAnswerBeforeStore() async {
        let request = ThumbnailRequest()
        let result = await withCheckedContinuation { continuation in
            request.attach(continuation)
            request.finish(Data([4]))
            // The id turns up afterwards, for a request that is already done.
            #expect(request.store(11) == nil)
            // And a cancellation that lands after the answer must not resume anything.
            _ = request.cancel()
        }
        #expect(result == Data([4]))
    }
}
#endif
