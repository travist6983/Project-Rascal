import Foundation
import Testing

@testable import Rascal

/// The client half of "three missions a day".
///
/// The server now fills `question`, `mission` and `mission_b` every day, where it used to fill
/// two. Almost nothing in the client had to change for that — the board groups by what the
/// response contains rather than by a list of slot names — and these tests exist to keep it that
/// way, plus to hold the two places that genuinely did change.
@MainActor
@Suite("Three missions a day")
struct ThreeMissionsTests {

    private let today = "2026-08-18"

    private func assignment(
        id: UUID = UUID(),
        slot: String,
        kind: String,
        body: String = "Do the thing.",
        status: AssignmentStatus = .pending
    ) -> AssignmentResponse {
        AssignmentResponse(
            id: id, slot: slot, body: body, kind: kind, completionMode: "media",
            theme: nil, status: status, assignedOn: today, expiresOn: "2026-09-01",
            promptId: nil, isCustom: false, unlockAtAge: nil
        )
    }

    private func board(_ items: [AssignmentResponse]) -> TodayBoard {
        TodayBoard.merge(
            response: TodayResponse(
                date: today,
                child: ChildSummary(id: UUID(), name: "Miles Terry", ageMonths: 50),
                today: items, waiting: [], doneToday: []
            ),
            entries: [],
            media: []
        )
    }

    // MARK: The board renders whatever the day contains

    @Test("a three-daily-slot response produces three cards")
    func threeDailySlotsRenderThreeCards() {
        let question = assignment(slot: "question", kind: "question")
        let mission = assignment(slot: "mission", kind: "photo")
        let missionB = assignment(slot: "mission_b", kind: "audio")

        let board = self.board([question, mission, missionB])

        #expect(board.today.count == 3)
        #expect(Set(board.today.map(\.assignment.slot)) == ["question", "mission", "mission_b"])
    }

    @Test("a five-item day renders five cards")
    func theWorstDayTheCalendarCanProduce() {
        // A Saturday that is also the 15th: the daily three, plus the weekly and the letter.
        let board = self.board([
            assignment(slot: "question", kind: "question"),
            assignment(slot: "mission", kind: "photo"),
            assignment(slot: "mission_b", kind: "video"),
            assignment(slot: "weekly", kind: "activity"),
            assignment(slot: "letter", kind: "letter"),
        ])

        #expect(board.today.count == 5)
    }

    // MARK: mission_b is a real slot, not an unknown one

    @Test("mission_b is recognised, so it is never the grey fallback card")
    func missionBIsRecognised() {
        let missionB = assignment(slot: "mission_b", kind: "video")

        #expect(missionB.slotKind == .missionB)
        #expect(missionB.isRecognised)
        // An unrecognised slot renders `.inkMuted` on `.surface`. One of the three cards a
        // parent sees every day must not look like a value from a future server release.
        #expect(missionB.tint == .terracotta)
    }

    @Test("an audio mission_b is still periwinkle, because colour follows the kind")
    func audioKeepsItsColour() {
        let voice = assignment(slot: "mission_b", kind: "audio")
        #expect(voice.tint == .periwinkle)
    }

    @Test("both daily missions read Mission, with no A and B in the copy")
    func neitherMissionIsNumbered() {
        #expect(Slot.mission.displayName == "Mission")
        #expect(Slot.missionB.displayName == "Mission")
    }

    @Test("mission_b round-trips through the raw value the server sends")
    func rawValueRoundTrip() {
        #expect(Slot(rawValue: "mission_b") == .missionB)
        #expect(Slot.missionB.rawValue == "mission_b")
    }

    // MARK: The widget picks one of the two

    @Test("the widget shows the photo mission when there is one")
    func widgetPrefersThePhotoMission() {
        let mission = assignment(slot: "mission", kind: "photo")
        let missionB = assignment(slot: "mission_b", kind: "activity")

        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board([missionB, mission]),  // deliberately out of order
            familyTimezone: "America/Detroit"
        )

        #expect(snapshot.mission?.assignmentId == mission.id)
    }

    @Test("the widget falls back to mission_b when the photo pool came up empty")
    func widgetFallsBackToTheSecondMission() {
        // Not hypothetical: `mission` draws from the photo pool, the thinnest of the three, so
        // an empty `mission` is the case this fallback exists for. Without it the widget would
        // show no mission at all while one sat on the Today board.
        let missionB = assignment(slot: "mission_b", kind: "audio", body: "Record him singing.")

        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board([assignment(slot: "question", kind: "question"), missionB]),
            familyTimezone: "America/Detroit"
        )

        #expect(snapshot.mission?.assignmentId == missionB.id)
        #expect(snapshot.mission?.body == "Record him singing.")
    }

    @Test("a dismissed mission does not promote mission_b past the rules")
    func dismissedMissionFallsThrough() {
        // A dismissed assignment is nothing to show, so the fallback should reach mission_b
        // rather than surfacing something the parent already said no to.
        let dismissed = assignment(slot: "mission", kind: "photo", status: .dismissed)
        let missionB = assignment(slot: "mission_b", kind: "activity")

        let snapshot = WidgetSnapshotBuilder.snapshot(
            from: board([dismissed, missionB]),
            familyTimezone: "America/Detroit"
        )

        #expect(snapshot.mission?.assignmentId == missionB.id)
    }
}
