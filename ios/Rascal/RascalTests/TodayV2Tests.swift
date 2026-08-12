import Foundation
import Testing

@testable import Rascal

/// Today v2 — the logic behind the redesigned board.
///
/// Two things here are worth more than the rest. The expiry arithmetic used to anchor on the
/// *device's* day while `expires_on` is computed in the child's `family_timezone`, which is the
/// client deciding what day it is; every case below is a pair of server-named days and no `Date()`
/// appears anywhere, which is the property that fix bought. And the skip window holds a real
/// network request back for eight seconds so it can be taken back — a mechanism that can lose a
/// parent's intent in about four different ways if it is wrong.
@MainActor
@Suite("Today v2")
struct TodayV2Tests {

    private func assignment(
        slot: String = "mission",
        kind: String = "photo",
        mode: String = "media",
        body: String = "Take a photo",
        assignedOn: String = "2026-08-11",
        expiresOn: String? = "2026-08-25",
        status: AssignmentStatus = .pending
    ) -> AssignmentResponse {
        AssignmentResponse(
            id: UUID(), slot: slot, body: body, kind: kind, completionMode: mode,
            theme: nil, status: status, assignedOn: assignedOn, expiresOn: expiresOn,
            promptId: nil, isCustom: false, unlockAtAge: nil
        )
    }

    // MARK: Expiry — measured between two days the server named

    @Test("the expiry chip appears only inside the three-day window")
    func expiryWindow() {
        let today = "2026-08-11"
        #expect(assignment(expiresOn: "2026-08-15").expiryLabel(asOf: today) == nil, "four days out says nothing")
        #expect(assignment(expiresOn: "2026-08-14").expiryLabel(asOf: today) == "3 days left")
        #expect(assignment(expiresOn: "2026-08-13").expiryLabel(asOf: today) == "2 days left")
        #expect(assignment(expiresOn: "2026-08-12").expiryLabel(asOf: today) == "1 day left")
        #expect(assignment(expiresOn: "2026-08-11").expiryLabel(asOf: today) == "Last day")
    }

    @Test("an assignment with no expiry, or one already past, says nothing at all")
    func expirySilentCases() {
        let today = "2026-08-11"
        #expect(assignment(expiresOn: nil).expiryLabel(asOf: today) == nil)
        #expect(assignment(expiresOn: "2026-08-10").expiryLabel(asOf: today) == nil, "the server decides what expired")
        #expect(assignment(expiresOn: "not-a-date").expiryLabel(asOf: today) == nil)
        #expect(assignment(expiresOn: "2026-08-13").expiryLabel(asOf: "nonsense") == nil)
    }

    /// The old implementation could not have passed this: it measured from `Date()`, so its answer
    /// depended on the day the suite ran and the zone of the machine running it.
    @Test("expiry is a pure function of two server dates — no device clock, no device zone")
    func expiryIsPure() {
        #expect(assignment(expiresOn: "2026-09-01").expiryLabel(asOf: "2026-08-30") == "2 days left", "month boundary")
        #expect(assignment(expiresOn: "2027-01-01").expiryLabel(asOf: "2026-12-31") == "1 day left", "year boundary")
        #expect(assignment(expiresOn: "2028-02-29").expiryLabel(asOf: "2028-02-28") == "1 day left", "leap day")
        // The DST pairs are the sharp ones. A day-difference taken in a zone that observes DST
        // spans 23 or 25 hours across these boundaries, so an implementation that measured elapsed
        // time — or leaned on `Calendar.current` — rounds one of them to the wrong day. Both are
        // exactly one day apart in the child's calendar, and that is what the chip must say.
        #expect(assignment(expiresOn: "2026-03-09").expiryLabel(asOf: "2026-03-08") == "1 day left", "US DST spring forward")
        #expect(assignment(expiresOn: "2026-11-02").expiryLabel(asOf: "2026-11-01") == "1 day left", "US DST fall back")

        // Called twice with identical arguments, it answers identically — there is no `Date()`
        // inside it to drift, which is the property the old device-anchored version lacked.
        let subject = assignment(expiresOn: "2026-08-13")
        #expect(subject.expiryLabel(asOf: "2026-08-11") == "2 days left")
        #expect(subject.expiryLabel(asOf: "2026-08-11") == subject.expiryLabel(asOf: "2026-08-11"))
    }

    // MARK: How long something has waited

    @Test("a waiting item says how long it has waited, and stops being specific after a week")
    func waitingSince() {
        let today = "2026-08-11"
        #expect(assignment(assignedOn: "2026-08-11").waitingSinceLabel(asOf: today) == nil, "today is not waiting")
        #expect(assignment(assignedOn: "2026-08-10").waitingSinceLabel(asOf: today) == "Yesterday")
        #expect(assignment(assignedOn: "2026-08-09").waitingSinceLabel(asOf: today) == "2 days ago")
        #expect(assignment(assignedOn: "2026-08-05").waitingSinceLabel(asOf: today) == "6 days ago")
        #expect(assignment(assignedOn: "2026-08-04").waitingSinceLabel(asOf: today) == "Earlier")
        #expect(assignment(assignedOn: "2026-01-01").waitingSinceLabel(asOf: today) == "Earlier", "never an audit")
        #expect(assignment(assignedOn: "2026-08-12").waitingSinceLabel(asOf: today) == nil, "a future date says nothing")
    }

    // MARK: The quiet line under a live prompt

    @Test("the footnote names the slot and counts nothing")
    func footnotes() {
        let today = "2026-08-11"
        #expect(assignment(slot: "mission").footnoteLabel(asOf: today) == "Today's mission")
        #expect(assignment(slot: "question").footnoteLabel(asOf: today) == "Today's question")
        #expect(assignment(slot: "weekly").footnoteLabel(asOf: today) == "All week to finish")
        #expect(assignment(slot: "monthly").footnoteLabel(asOf: today) == "Any time this month")
        #expect(assignment(slot: "letter").footnoteLabel(asOf: today) == "A letter, for later")
        #expect(assignment(slot: "hologram").footnoteLabel(asOf: today) == "Still open", "an unknown slot is not a crash")
        #expect(
            assignment(slot: "mission", assignedOn: "2026-08-09").footnoteLabel(asOf: today) == "Still open",
            "a carried-over mission is not today's"
        )
    }

    @Test("a done row names the shape of thing that landed, not the prompt's kind")
    func completedDescriptions() {
        #expect(assignment(kind: "activity", mode: "did_it").completedDescription == "Did it")
        #expect(assignment(kind: "question", mode: "text").completedDescription == "Written")
        #expect(assignment(kind: "photo", mode: "media").completedDescription == "Photo")
        #expect(assignment(kind: "audio", mode: "media").completedDescription == "Voice")
        #expect(assignment(kind: "video", mode: "media").completedDescription == "Video")
        #expect(assignment(kind: "photo", mode: "telepathy").completedDescription == "Saved")
    }

    // MARK: Colour carries meaning

    @Test("questions and voice are periwinkle, everything recognised is terracotta, unknown is neither")
    func tints() {
        #expect(assignment(slot: "question", kind: "question").tint == .periwinkle)
        #expect(assignment(kind: "audio").tint == .periwinkle, "voice is periwinkle even in a mission slot")
        #expect(assignment(kind: "photo").tint == .terracotta)
        #expect(assignment(kind: "video").tint == .terracotta)
        #expect(assignment(kind: "hologram").tint == .inkMuted, "an unknown kind is never given a guessed tint")
        #expect(assignment(kind: "hologram").softTint == .surface, "and renders as a neutral card")
        #expect(assignment(slot: "question", kind: "question").tintBorder == .periwinkleBorder)
    }

    // MARK: The end of the board

    @Test("all caught up requires having caught up with something")
    func endOfBoard() {
        #expect(AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 0, doneToday: 3) == .caughtUp(doneToday: 3))
        #expect(AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 0, doneToday: 0) == .nothingYet)
        #expect(
            AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 2, doneToday: 3) == nil,
            "two prompts still waiting is not caught up"
        )
        #expect(AllCaughtUpCard.Mode.forBoard(today: 1, waiting: 0, doneToday: 3) == nil)
        #expect(AllCaughtUpCard.Mode.forBoard(today: 1, waiting: 1, doneToday: 0) == nil)
    }

    // MARK: The toast's sentence

    @Test("the skipped toast quotes the prompt without running off the screen")
    func skipLabels() {
        func label(_ body: String, for subject: PromptSubject = .unknown) -> String {
            TodayModel.PendingSkip(assignment: assignment(body: body)).label(for: subject)
        }
        #expect(label("Photograph the mess.") == "Skipped “Photograph the mess”")
        #expect(label("No trailing period") == "Skipped “No trailing period”")
        #expect(label("") == "Skipped “”", "an empty body is not a crash")

        let long = String(repeating: "word ", count: 40)
        let shown = label(long)
        #expect(shown.hasSuffix("…”"), "a long body is cut short")
        #expect(shown.count < 80, "and the toast stays one or two lines")

        let oneWord = String(repeating: "x", count: 200)
        #expect(label(oneWord).count < 80, "including a body with nowhere to break")

        // The toast quotes the sentence the card was showing a moment ago, so it renders tokens
        // too — and it substitutes *before* truncating, or the braces would count towards the 60.
        #expect(
            label("Photograph {their} mess.", for: PromptSubject(name: "Ada", pronouns: .sheHer))
                == "Skipped “Photograph her mess”"
        )
        #expect(
            label("Photograph {their} mess.") == "Skipped “Photograph their mess”",
            "an unanswered pronoun reads the they/them column here as everywhere else"
        )
    }
}

/// The skip window: a dismissal the parent can take back, because the server has no un-dismiss.
///
/// `POST /assignments/{id}/dismiss` is one-way. The only honest undo is to not have sent it yet, so
/// what these tests actually assert is *when the request goes out* — which is the whole mechanism.
/// A board with nothing on it, for the refetch that follows a dismissal.
///
/// Top-level rather than a static on the suite: the suite is `@MainActor`, and `StubPerformer`
/// answers from a `@Sendable` closure that cannot reach main-actor state.
private let emptyBoardJSON = """
{"date":"2026-08-11","child":{"id":"6E5B0E4E-9C2F-4E5A-9F1B-2C3D4E5F6071","name":"Hendrix","age_months":62},
 "today":[],"waiting":[],"done_today":[]}
"""

/// A performer that refuses to answer a cancelled task, the way `URLSession` does.
///
/// `StubPerformer` answers regardless, which is fine for every other suite and blind to exactly one
/// bug: the grace-window task committing the skip *from inside itself* after cancelling itself.
/// That shipped green against the plain stub and would have failed on every phone, because
/// `URLSession.data(for:)` throws `CancellationError` rather than making the request.
private final class CancellationAwarePerformer: HTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private(set) var sawCancellation = false

    var dismissCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return sawCancellation
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path() ?? ""
        do {
            try Task.checkCancellation()
        } catch {
            recordCancellation()
            throw error
        }
        record(path: path)
        let body = path.contains("today") ? Data(emptyBoardJSON.utf8) : Data("{}".utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // Synchronous by design — taking a lock directly inside an `async` function is what the
    // compiler objects to. Same shape as `StubPerformer`.
    private func recordCancellation() {
        lock.lock(); defer { lock.unlock() }
        sawCancellation = true
    }

    private func record(path: String) {
        lock.lock(); defer { lock.unlock() }
        if path.contains("dismiss") { sent += 1 }
    }
}

@MainActor
@Suite("Today v2 — skip and undo")
struct TodaySkipTests {

    /// Spin until something becomes true, rather than sleeping a fixed interval and hoping.
    ///
    /// The suite runs in parallel with fifty others, all competing for the main actor, so a timer
    /// set for 120ms can genuinely land half a second later. A fixed sleep here is a test that
    /// passes on a quiet machine and fails on a busy one.
    private func waitUntil(
        _ label: Comment,
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for: \(label)")
    }

    private func model(_ performer: StubPerformer, grace: Duration = .milliseconds(50)) -> TodayModel {
        TodayModel(
            childId: UUID(),
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            skipGrace: grace
        )
    }

    private func assignment(_ body: String = "Take a photo") -> AssignmentResponse {
        AssignmentResponse(
            id: UUID(), slot: "mission", body: body, kind: "photo", completionMode: "media",
            theme: nil, status: .pending, assignedOn: "2026-08-11", expiresOn: nil,
            promptId: nil, isCustom: false, unlockAtAge: nil
        )
    }

    @Test("a skip sends nothing while the parent can still take it back")
    func skipDefersTheRequest() async throws {
        let performer = StubPerformer()
        let subject = model(performer, grace: .seconds(30))

        subject.skip(assignment())

        #expect(subject.pendingSkip != nil, "the toast is showing")
        #expect(performer.count(for: "dismiss") == 0, "and nothing has been dismissed yet")
    }

    @Test("undo means the request is never sent at all")
    func undoNeverSends() async throws {
        let performer = StubPerformer()
        let subject = model(performer)

        subject.skip(assignment())
        subject.undoSkip()

        #expect(subject.pendingSkip == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(performer.count(for: "dismiss") == 0, "the window elapsed and still nothing went out")
    }

    @Test("letting the window elapse sends the dismissal exactly once")
    func elapsingSendsOnce() async throws {
        let performer = StubPerformer()
        performer.on("dismiss") { _ in (Data("{}".utf8), 200) }
        performer.on("today") { _ in (Data(emptyBoardJSON.utf8), 200) }
        let subject = model(performer)

        subject.skip(assignment())
        try await waitUntil("the held dismissal to go out") { performer.count(for: "dismiss") == 1 }

        #expect(subject.pendingSkip == nil, "the toast is gone")
        #expect(performer.count(for: "dismiss") == 1, "and it went exactly once")
    }

    @Test("a second skip commits the first rather than dropping it")
    func secondSkipCommitsTheFirst() async throws {
        let performer = StubPerformer()
        performer.on("dismiss") { _ in (Data("{}".utf8), 200) }
        performer.on("today") { _ in (Data(emptyBoardJSON.utf8), 200) }
        let subject = model(performer, grace: .seconds(30))

        subject.skip(assignment("The first one"))
        subject.skip(assignment("The second one"))

        // The parent watched the first row leave. It must not come back because they skipped
        // another one before the window closed.
        try await waitUntil("the first skip to be committed") { performer.count(for: "dismiss") == 1 }
        #expect(subject.pendingSkip?.assignment.body == "The second one", "and the second is still undoable")
    }

    @Test("leaving the screen commits a held skip instead of losing it")
    func backgroundingCommits() async throws {
        let performer = StubPerformer()
        performer.on("dismiss") { _ in (Data("{}".utf8), 200) }
        performer.on("today") { _ in (Data(emptyBoardJSON.utf8), 200) }
        let subject = model(performer, grace: .seconds(30))

        subject.skip(assignment())
        await subject.commitPendingSkip()

        #expect(performer.count(for: "dismiss") == 1)
        #expect(subject.pendingSkip == nil)
    }

    /// The regression test for the sharpest bug in this phase.
    @Test("the timed skip is not made on a task it has just cancelled")
    func elapsedSkipIsNotCancelled() async throws {
        let performer = CancellationAwarePerformer()
        let subject = TodayModel(
            childId: UUID(),
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            skipGrace: .milliseconds(50)
        )

        subject.skip(assignment())
        try await waitUntil("the elapsed skip to reach the server") { performer.dismissCount == 1 }

        #expect(performer.wasCancelled == false, "the request was never made on a cancelled task")
        #expect(subject.notice == nil, "so the parent is not told their skip failed")
    }

    @Test("a skipped row stays gone while its request is still in flight")
    func hiddenUntilTheServerAgrees() async throws {
        let performer = StubPerformer()
        performer.on("dismiss") { _ in (Data("{}".utf8), 200) }
        performer.on("today") { _ in (Data(emptyBoardJSON.utf8), 200) }
        let subject = model(performer, grace: .seconds(30))

        let first = assignment("The first one")
        subject.skip(first)
        #expect(subject.hiddenSkips.contains(first.id))

        // A second skip commits the first. The first must not reappear on the board in the gap
        // between losing the toast and the server confirming.
        subject.skip(assignment("The second one"))
        #expect(subject.hiddenSkips.contains(first.id), "still hidden while the request is in flight")

        try await waitUntil("the first request to settle") { !subject.hiddenSkips.contains(first.id) }
    }

    @Test("undo puts the row back on the board")
    func undoUnhides() {
        let performer = StubPerformer()
        let subject = model(performer, grace: .seconds(30))
        let one = assignment()

        subject.skip(one)
        #expect(subject.hiddenSkips.contains(one.id))
        subject.undoSkip()
        #expect(subject.hiddenSkips.isEmpty, "the row is visible again")
    }

    @Test("committing when nothing is held is a no-op, not a stray request")
    func commitWithNothingHeld() async throws {
        let performer = StubPerformer()
        let subject = model(performer)

        await subject.commitPendingSkip()
        await subject.commitPendingSkip()

        #expect(performer.count(for: "dismiss") == 0)
    }

    @Test("a dismissal the server refuses surfaces as a quiet notice, never as lost work")
    func failureIsQuiet() async throws {
        let performer = StubPerformer()
        performer.on("dismiss") { _ in (Data(#"{"error":{"code":"server_error","message":"nope"}}"#.utf8), 500) }
        let subject = model(performer, grace: .seconds(30))

        subject.skip(assignment())
        // Committed directly rather than waiting out the window: a 500 sends `APIClient` into its
        // retry backoff, so sleeping a fixed interval and then asserting races the request. This
        // awaits the same code path the timer would have run.
        await subject.commitPendingSkip()

        #expect(subject.notice != nil, "the parent is told, once, in a line")
        #expect(subject.pendingSkip == nil, "and the toast does not stay up over a failure")
    }

}
