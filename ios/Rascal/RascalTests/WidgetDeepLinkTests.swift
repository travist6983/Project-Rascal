import Foundation
import Testing

@testable import Rascal

/// The URL the widget opens the app with, and where it lands.
@MainActor
@Suite("Widget deep link")
struct WidgetDeepLinkTests {

    private let assignmentId = UUID(uuidString: "9E1B0F6A-2C4D-4A7B-9F31-8C55A0D2E410")!

    // MARK: The URL

    @Test("an assignment link round-trips through its own URL")
    func assignmentRoundTrip() {
        let url = WidgetDeepLink.assignment(assignmentId).url
        #expect(url.scheme == "childarchive")
        #expect(WidgetDeepLink.parse(url) == .assignment(assignmentId))
    }

    @Test("the today link round-trips")
    func todayRoundTrip() {
        #expect(WidgetDeepLink.parse(WidgetDeepLink.today.url) == .today)
    }

    @Test("a UUID's case does not change where it lands")
    func uuidCaseIsIrrelevant() {
        let upper = URL(string: "childarchive://assignment/\(assignmentId.uuidString)")!
        let lower = URL(string: "childarchive://assignment/\(assignmentId.uuidString.lowercased())")!
        #expect(WidgetDeepLink.parse(upper) == .assignment(assignmentId))
        #expect(WidgetDeepLink.parse(lower) == .assignment(assignmentId))
    }

    /// **Anything wearing our scheme that cannot be read lands on Today.** A widget tapped is a
    /// parent expecting the app to open somewhere real, and the one outcome that must be
    /// impossible is a composer opened for an assignment that does not exist.
    @Test("a malformed link of ours still lands somewhere real")
    func malformedLandsOnToday() {
        let cases = [
            "childarchive://assignment/not-a-uuid",
            "childarchive://assignment",
            "childarchive://assignment/",
            "childarchive://something-else",
            "childarchive://",
        ]
        for raw in cases {
            guard let url = URL(string: raw) else { continue }
            #expect(WidgetDeepLink.parse(url) == .today, "\(raw) did not land on Today")
        }
    }

    @Test("a foreign scheme is left alone")
    func foreignSchemeIsIgnored() {
        #expect(WidgetDeepLink.parse(URL(string: "https://example.com/assignment/x")!) == nil)
        #expect(WidgetDeepLink.parse(URL(string: "mailto:someone@example.com")!) == nil)
    }

    // MARK: Where it lands

    private let today = "2026-08-10"

    private func assignment(
        id: UUID,
        slot: String = "mission",
        status: AssignmentStatus = .pending,
        assignedOn: String? = nil
    ) -> AssignmentResponse {
        AssignmentResponse(
            id: id, slot: slot, body: "Take a photo", kind: "photo", completionMode: "media",
            theme: nil, status: status, assignedOn: assignedOn ?? today, expiresOn: nil,
            promptId: nil, isCustom: false, unlockAtAge: nil
        )
    }

    private func board(
        today items: [AssignmentResponse] = [],
        waiting: [AssignmentResponse] = [],
        done: [AssignmentResponse] = [],
        entries: [Entry] = []
    ) -> TodayBoard {
        TodayBoard.merge(
            response: TodayResponse(
                date: today,
                child: ChildSummary(id: UUID(), name: "Sam", ageMonths: 62),
                today: items, waiting: waiting, doneToday: done
            ),
            entries: entries,
            media: []
        )
    }

    @Test("a valid assignment id opens the composer for that assignment")
    func validIdOpensComposer() {
        let target = assignment(id: assignmentId)
        #expect(board(today: [target]).route(forAssignment: assignmentId) == .composer(target))
    }

    /// The assertion the whole route exists for.
    @Test("an id this board has never heard of lands on Today, not on a broken composer")
    func unknownIdLandsOnToday() {
        #expect(board(today: [assignment(id: UUID())]).route(forAssignment: assignmentId) == .today)
        #expect(board().route(forAssignment: assignmentId) == .today)
    }

    /// A snapshot can outlive the day it was written for, so an id arriving from the widget may
    /// belong to a prompt that has since rolled over into the backlog. It still opens — the
    /// parent tapped it deliberately — and it is the unknown id that gets turned away, not the
    /// old one.
    @Test("a stale id that is still on the board opens rather than being refused")
    func staleButPresentIdStillOpens() {
        let old = assignment(id: assignmentId, assignedOn: "2026-08-03")
        #expect(board(waiting: [old]).route(forAssignment: assignmentId) == .composer(old))
    }

    /// A snapshot outliving the prompt it named: the widget still holds Tuesday's id, and the
    /// board has moved on to a full day of other work. The busy board is the point — the earlier
    /// test uses an almost-empty one, and an id can only be turned away if the search actually
    /// covers everything the board holds.
    @Test("a stale id for a prompt that has since expired off the board lands on Today")
    func staleAndGoneLandsOnToday() {
        let done = assignment(id: UUID(), status: .done)
        let populated = board(
            today: [assignment(id: UUID()), assignment(id: UUID(), slot: "question")],
            waiting: [assignment(id: UUID(), assignedOn: "2026-08-02")],
            done: [done],
            entries: [Entry(childId: UUID(), assignmentId: done.id, occurredAt: Date())]
        )

        #expect(populated.route(forAssignment: assignmentId) == .today)
    }

    @Test("a finished assignment opens the entry it produced")
    func doneOpensItsEntry() {
        let target = assignment(id: assignmentId, status: .done)
        let entry = Entry(childId: UUID(), assignmentId: assignmentId, occurredAt: Date())

        #expect(board(done: [target], entries: [entry]).route(forAssignment: assignmentId) == .entry(entry.id))
    }

    /// Completed on another phone and not yet pulled down here: there is no entry to open, and
    /// Today is the honest landing rather than an empty composer for a finished prompt.
    @Test("a finished assignment with no local entry lands on Today")
    func doneWithoutLocalEntryLandsOnToday() {
        let target = assignment(id: assignmentId, status: .done)
        #expect(board(done: [target]).route(forAssignment: assignmentId) == .today)
    }
}
