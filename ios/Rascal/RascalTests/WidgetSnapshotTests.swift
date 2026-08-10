import Foundation
import Testing

@testable import Rascal

/// The contract between the app and the extension.
///
/// The widget cannot be unit tested — a `Widget` is only ever instantiated by WidgetKit — so
/// everything that decides what it renders lives in types the app target owns, and this is where
/// those decisions are held to account.
@MainActor
@Suite("Widget snapshot")
struct WidgetSnapshotTests {

    // MARK: Fixtures

    private static let mission = WidgetSnapshot.Item(
        assignmentId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        body: "Photograph the thing he carries everywhere right now.",
        kind: "photo",
        isDone: false
    )

    private static let question = WidgetSnapshot.Item(
        assignmentId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        body: "What did he say today that you want to remember?",
        kind: "question",
        isDone: false
    )

    private func snapshot(
        assignedOn: String = "2026-08-10",
        timezone: String = "America/New_York",
        name: String = "Sam",
        mission: WidgetSnapshot.Item? = WidgetSnapshotTests.mission,
        question: WidgetSnapshot.Item? = WidgetSnapshotTests.question
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            assignedOn: assignedOn,
            familyTimezone: timezone,
            childFirstName: name,
            mission: mission,
            question: question
        )
    }

    /// An instant, stated unambiguously in UTC.
    private func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    // MARK: Round trip

    @Test("encodes and decodes without losing anything")
    func roundTrip() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        #expect(decoded == original)
        #expect(decoded.version == WidgetSnapshot.currentVersion)
        #expect(decoded.mission?.assignmentId == Self.mission.assignmentId)
        #expect(decoded.question?.body == Self.question.body)
    }

    @Test("a snapshot with neither prompt still round-trips")
    func roundTripEmpty() throws {
        let original = snapshot(mission: nil, question: nil)
        let decoded = try JSONDecoder().decode(
            WidgetSnapshot.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.isEmpty)
    }

    // MARK: Staleness, in the child's timezone

    /// **The assertion that matters, and it is deliberately set where UTC disagrees.**
    ///
    /// 03:30 UTC on 11 August is still 23:30 on 10 August in New York. A snapshot assigned on the
    /// 10th is therefore current for that child — and a staleness check written against UTC, or
    /// against the device's own zone, would call it stale and blank the widget four and a half
    /// hours early, every night. The reverse case is below.
    @Test("a snapshot is current in the child's zone even when UTC has already rolled over")
    func currentInChildZoneWhileUTCHasMovedOn() {
        let state = WidgetSnapshotState.resolve(
            snapshot(assignedOn: "2026-08-10", timezone: "America/New_York"),
            now: instant("2026-08-11T03:30:00Z")
        )

        #expect(state == .current(snapshot(assignedOn: "2026-08-10", timezone: "America/New_York")))
    }

    /// The other direction. 13:00 UTC on 10 August is already the 11th in Auckland, so a snapshot
    /// stamped the 10th is yesterday's there — and must not be drawn as today's.
    @Test("a snapshot is stale in the child's zone before UTC has rolled over")
    func staleInChildZoneWhileUTCHasNot() {
        let state = WidgetSnapshotState.resolve(
            snapshot(assignedOn: "2026-08-10", timezone: "Pacific/Auckland"),
            now: instant("2026-08-10T13:00:00Z")
        )

        #expect(state == .stale(childFirstName: "Sam"))
    }

    @Test("a snapshot from a previous day is stale")
    func previousDayIsStale() {
        let state = WidgetSnapshotState.resolve(
            snapshot(assignedOn: "2026-08-09", timezone: "America/New_York"),
            now: instant("2026-08-10T16:00:00Z")
        )
        #expect(state == .stale(childFirstName: "Sam"))
    }

    /// A stale state cannot carry a prompt, and that is the point of its shape.
    ///
    /// This is the defect the whole staleness rule exists to prevent: yesterday's mission
    /// presented as today's. Making it unreachable from the case beats remembering not to draw it.
    @Test("a stale state carries no prompt at all")
    func staleCarriesNothingToRender() {
        let state = WidgetSnapshotState.resolve(
            snapshot(assignedOn: "2026-08-01"),
            now: instant("2026-08-10T16:00:00Z")
        )

        guard case .stale(let name) = state else {
            Issue.record("expected stale, got \(state)")
            return
        }
        #expect(name == "Sam")
    }

    @Test("a timezone this device has never heard of is treated as unverifiable, not as today")
    func unknownTimezoneIsStale() {
        let state = WidgetSnapshotState.resolve(
            snapshot(assignedOn: "2026-08-10", timezone: "Mars/Olympus_Mons"),
            now: instant("2026-08-10T16:00:00Z")
        )
        #expect(state == .stale(childFirstName: "Sam"))
    }

    @Test("the day is read in the stated zone, not the device's")
    func dayIsComputedInTheGivenZone() {
        let moment = instant("2026-08-11T03:30:00Z")
        #expect(WidgetSnapshot.day(for: moment, in: TimeZone(identifier: "America/New_York")!) == "2026-08-10")
        #expect(WidgetSnapshot.day(for: moment, in: TimeZone(identifier: "UTC")!) == "2026-08-11")
        #expect(WidgetSnapshot.day(for: moment, in: TimeZone(identifier: "Pacific/Auckland")!) == "2026-08-11")
    }

    @Test("a single-digit month and day are zero padded, so the comparison with the server holds")
    func dayIsZeroPadded() {
        let moment = instant("2026-01-05T12:00:00Z")
        #expect(WidgetSnapshot.day(for: moment, in: TimeZone(identifier: "UTC")!) == "2026-01-05")
    }

    // MARK: Nothing to read

    @Test("a missing snapshot resolves to the neutral state without throwing")
    func missingIsAbsent() {
        #expect(WidgetSnapshotState.resolve(data: nil, now: .now) == .absent)
        #expect(WidgetSnapshotState.resolve(data: Data(), now: .now) == .absent)
    }

    @Test("a corrupt snapshot resolves to the neutral state without throwing")
    func corruptIsAbsent() {
        let truncated = Data(#"{"version":1,"assignedOn":"2026-08-1"#.utf8)
        #expect(WidgetSnapshotState.resolve(data: truncated, now: .now) == .absent)

        let garbage = Data([0xFF, 0x00, 0x13, 0x37, 0xFE])
        #expect(WidgetSnapshotState.resolve(data: garbage, now: .now) == .absent)

        let wrongShape = Data(#"{"version":1,"assignedOn":42}"#.utf8)
        #expect(WidgetSnapshotState.resolve(data: wrongShape, now: .now) == .absent)
    }

    @Test("a snapshot written by a different version resolves to the neutral state")
    func versionMismatchIsAbsent() throws {
        let future = WidgetSnapshot(
            version: WidgetSnapshot.currentVersion + 1,
            assignedOn: "2026-08-10",
            familyTimezone: "America/New_York",
            childFirstName: "Sam",
            mission: Self.mission,
            question: Self.question
        )
        let data = try JSONEncoder().encode(future)

        // Absent rather than stale: an unrecognised version means the fields cannot be trusted to
        // mean what this build thinks they mean, including the name.
        #expect(WidgetSnapshotState.resolve(data: data, now: instant("2026-08-10T16:00:00Z")) == .absent)
    }

    // MARK: What the families lead with

    @Test("the lead is the first unfinished prompt, mission before question")
    func nextUpPrefersMission() {
        #expect(snapshot().nextUp?.label == "Mission")

        let missionDone = snapshot(
            mission: WidgetSnapshot.Item(
                assignmentId: Self.mission.assignmentId,
                body: Self.mission.body,
                kind: Self.mission.kind,
                isDone: true
            )
        )
        #expect(missionDone.nextUp?.label == "Question")
    }

    @Test("both finished is a state of its own, and leads with nothing")
    func completeHasNoLead() {
        let done = { (item: WidgetSnapshot.Item) in
            WidgetSnapshot.Item(
                assignmentId: item.assignmentId, body: item.body, kind: item.kind, isDone: true
            )
        }
        let snapshot = snapshot(mission: done(Self.mission), question: done(Self.question))

        #expect(snapshot.isComplete)
        #expect(snapshot.nextUp == nil)
        #expect(!snapshot.isEmpty)
    }

    @Test("a day with no prompts is empty rather than complete")
    func emptyIsNotComplete() {
        let snapshot = snapshot(mission: nil, question: nil)
        #expect(snapshot.isEmpty)
        #expect(!snapshot.isComplete)
        #expect(snapshot.nextUp == nil)
    }

    // MARK: The symbol, which is the Lock Screen's only channel

    /// The snapshot's symbol map mirrors `PromptKind.symbol` rather than calling it, because the
    /// extension is deliberately not given the API wire model. That duplication is only safe if
    /// something notices when the two disagree.
    @Test("every prompt kind maps to the same symbol the app's PromptCard uses")
    func symbolMatchesPromptKind() {
        for raw in ["question", "photo", "video", "audio", "activity", "letter"] {
            let item = WidgetSnapshot.Item(assignmentId: UUID(), body: "x", kind: raw, isDone: false)
            #expect(
                item.symbolName == PromptKind(rawValue: raw).symbol,
                "\(raw) renders as a different symbol on the Lock Screen than on the card"
            )
        }
    }

    @Test("a kind from a future server release still renders a symbol")
    func unknownKindHasASymbol() {
        let item = WidgetSnapshot.Item(assignmentId: UUID(), body: "x", kind: "hologram", isDone: false)
        #expect(item.symbolName == PromptKind(rawValue: "hologram").symbol)
    }

    // MARK: The day boundary

    @Test("the next refresh is the child's midnight, not the device's")
    func nextMidnightIsInTheChildsZone() throws {
        let snapshot = snapshot(assignedOn: "2026-08-10", timezone: "America/New_York")
        let midnight = try #require(snapshot.nextMidnight(after: instant("2026-08-10T16:00:00Z")))

        // 00:00 on 11 August in New York is 04:00 UTC.
        #expect(midnight == instant("2026-08-11T04:00:00Z"))
    }

    @Test("an unknown timezone has no midnight to aim at")
    func unknownZoneHasNoMidnight() {
        #expect(snapshot(timezone: "Mars/Olympus_Mons").nextMidnight(after: .now) == nil)
    }
}
