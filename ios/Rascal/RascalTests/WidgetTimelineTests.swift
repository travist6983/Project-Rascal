import Foundation
import Testing

@testable import Rascal

/// What the widget's timeline contains.
///
/// A `TimelineProvider` cannot be unit tested — only WidgetKit instantiates one — so the decision
/// it makes lives here instead, and this is where the day boundary is held to account.
@MainActor
@Suite("Widget timeline")
struct WidgetTimelineTests {

    private func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func snapshot(
        assignedOn: String = "2026-08-10",
        timezone: String = "America/New_York",
        name: String = "Sam"
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            assignedOn: assignedOn,
            familyTimezone: timezone,
            childFirstName: name,
            mission: WidgetSnapshot.Item(
                assignmentId: UUID(),
                body: "Photograph the thing he carries everywhere right now.",
                kind: "photo",
                isDone: false
            ),
            question: nil
        )
    }

    private var newYork: TimeZone { TimeZone(identifier: "America/New_York")! }

    // MARK: The rollover, which must not depend on a refresh being granted

    /// **The assertion this type exists for.**
    ///
    /// A timeline entry's state is frozen when the timeline is built. If the only thing turning a
    /// current snapshot into a stale one were the refresh requested by `.after(midnight)`, then a
    /// system that delayed or dropped that refresh — which WidgetKit is explicitly free to do,
    /// and refresh budget is out of the app's control — would leave yesterday's mission on the
    /// Home Screen presented as today's. That is the single defect the whole design exists to
    /// prevent, so the rollover is scheduled as data rather than requested as a favour.
    @Test("a current snapshot schedules its own expiry, without needing a refresh")
    func currentSnapshotSchedulesItsOwnStaleness() {
        let plan = WidgetTimelinePlan.make(
            state: .current(snapshot()),
            zone: newYork,
            now: instant("2026-08-10T23:00:00Z")   // 7pm in New York
        )

        #expect(plan.entries.count == 2)
        #expect(plan.entries[0].date == instant("2026-08-10T23:00:00Z"))

        // Midnight in New York on 11 August is 04:00 UTC.
        #expect(plan.entries[1].date == instant("2026-08-11T04:00:00Z"))
        #expect(plan.entries[1].state == .stale(childFirstName: "Sam"))
    }

    /// The scheduled entry is the neutral state, and it carries no prompt — the same guarantee
    /// `resolve` gives, made at timeline-build time instead.
    @Test("the scheduled rollover carries the name and nothing renderable")
    func rolloverCarriesNothingToRender() throws {
        let plan = WidgetTimelinePlan.make(
            state: .current(snapshot(name: "Sam")),
            zone: newYork,
            now: instant("2026-08-10T23:00:00Z")
        )

        guard case .stale(let name) = plan.entries[1].state else {
            Issue.record("the scheduled entry is not the neutral state")
            return
        }
        #expect(name == "Sam")
    }

    @Test("entries are in ascending date order and the list is never empty")
    func entriesAreOrdered() {
        for state in [
            WidgetSnapshotState.current(snapshot()),
            .stale(childFirstName: "Sam"),
            .absent,
        ] {
            let plan = WidgetTimelinePlan.make(
                state: state, zone: newYork, now: instant("2026-08-10T23:00:00Z")
            )
            #expect(!plan.entries.isEmpty)
            #expect(plan.entries == plan.entries.sorted { $0.date < $1.date })
        }
    }

    /// Stale and absent are already the neutral state; there is nothing for them to fall to, and
    /// a second identical entry would only spend a render.
    @Test("a state that is already neutral schedules nothing further")
    func neutralStatesScheduleNoRollover() {
        for state in [WidgetSnapshotState.stale(childFirstName: "Sam"), .absent] {
            let plan = WidgetTimelinePlan.make(
                state: state, zone: newYork, now: instant("2026-08-10T23:00:00Z")
            )
            #expect(plan.entries.count == 1, "\(state) scheduled a rollover it does not need")
        }
    }

    // MARK: The refresh request

    @Test("the refresh is aimed at the child's midnight, in every state")
    func refreshIsMidnight() {
        // Stale included: a stale widget waking hourly would spend a strictly limited budget
        // re-learning that it is still stale, and only the app can change that — and the app
        // pushes its own reload when it does.
        for state in [
            WidgetSnapshotState.current(snapshot()),
            .stale(childFirstName: "Sam"),
            .absent,
        ] {
            let plan = WidgetTimelinePlan.make(
                state: state, zone: newYork, now: instant("2026-08-10T23:00:00Z")
            )
            #expect(plan.refresh == instant("2026-08-11T04:00:00Z"))
        }
    }

    @Test("with no zone to read, the refresh is a backstop rather than a poll")
    func noZoneFallsBackToABackstop() {
        let now = instant("2026-08-10T23:00:00Z")
        let plan = WidgetTimelinePlan.make(state: .absent, zone: nil, now: now)

        #expect(plan.entries.count == 1)
        #expect(plan.refresh == now.addingTimeInterval(WidgetTimelinePlan.fallbackInterval))
        #expect(WidgetTimelinePlan.fallbackInterval >= 60 * 60, "a shorter interval is a poll")
    }

    /// A current snapshot with an unreadable zone cannot be given a midnight, so it cannot
    /// schedule its own expiry. It must still not schedule a rollover at a guessed time.
    @Test("a current snapshot with no zone schedules no rollover rather than a guessed one")
    func currentWithoutZoneSchedulesNothing() {
        let plan = WidgetTimelinePlan.make(
            state: .current(snapshot(timezone: "Mars/Olympus_Mons")),
            zone: nil,
            now: instant("2026-08-10T23:00:00Z")
        )
        #expect(plan.entries.count == 1)
    }

    /// A snapshot read a minute before midnight still gets a rollover a minute later, rather than
    /// one a whole day out.
    @Test("a snapshot built just before midnight rolls over minutes later")
    func justBeforeMidnight() {
        let plan = WidgetTimelinePlan.make(
            state: .current(snapshot()),
            zone: newYork,
            now: instant("2026-08-11T03:59:00Z")   // 23:59 in New York
        )
        #expect(plan.entries.count == 2)
        #expect(plan.entries[1].date == instant("2026-08-11T04:00:00Z"))
    }
}
