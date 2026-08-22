import Foundation
import Testing

@testable import Rascal

/// Phase 108 — the locked board, the membership sheet, the trial welcome.
///
/// The suite is organised around the two defects the phase brief predicts as most likely: an
/// optional decode that is optional in the model and force-unwrapped at the call site, and an
/// entitlement check that ended up in a view instead of in one place.
@Suite("Phase 108 — membership")
struct MembershipTests {

    // MARK: - The decode

    /// A `/today` payload as the API served it **before** phase 107 — no `access`, no
    /// `trial_ends_at`, no `locked`.
    private static let preEntitlementPayload = """
        {
          "date": "2026-08-21",
          "child": { "id": "\(fixedChildID)", "name": "Milo", "age_months": 50 },
          "today": [
            {
              "id": "\(fixedAssignmentID)",
              "slot": "question",
              "body": "What did {they} say this week that you want to remember exactly?",
              "kind": "question",
              "completion_mode": "text",
              "theme": null,
              "status": "pending",
              "assigned_on": "2026-08-21",
              "expires_on": null,
              "prompt_id": null,
              "is_custom": false,
              "unlock_at_age": null
            }
          ],
          "waiting": [],
          "done_today": []
        }
        """

    private static let fixedChildID = "11111111-1111-1111-1111-111111111111"
    private static let fixedAssignmentID = "22222222-2222-2222-2222-222222222222"

    private func decode(_ json: String) throws -> TodayResponse {
        try APIClient.decoder.decode(TodayResponse.self, from: Data(json.utf8))
    }

    /// **The build in TestFlight today, talking to a server that predates phase 107.**
    ///
    /// This is the test the whole decode design exists for. It must render exactly as it did before
    /// this phase: no locked cards, no empty state, no crash — and, above all, **no paywall.**
    @Test("a payload with access, trial_ends_at and locked all absent renders the full board")
    func absentEntitlementFieldsRenderTheFullBoard() throws {
        let response = try decode(Self.preEntitlementPayload)

        #expect(response.access == .notReported)
        #expect(response.trialEndsAt == nil)
        #expect(response.locked.isEmpty, "an absent locked array must decode as empty, never nil")

        // The load-bearing line: not-known means entitled.
        #expect(response.access.isEntitled)
        #expect(response.access.wasReported == false)

        let board = TodayBoard.merge(response: response, entries: [], media: [])
        #expect(board.today.count == 1)
        #expect(board.locked.isEmpty, "a board nobody told about entitlement must draw no locks")
    }

    /// `locked: []` is what the server sends a household that is entitled. It must produce no cards
    /// **and no empty-state view** — an empty section is furniture.
    @Test("an explicitly empty locked array renders no locked cards and no empty state")
    @MainActor
    func emptyLockedArrayRendersNothing() throws {
        let json = Self.preEntitlementPayload
            .replacingOccurrences(of: "\"done_today\": []", with: """
                "done_today": [], "access": "subscribed", "trial_ends_at": null, "locked": []
                """)

        let response = try decode(json)
        #expect(response.access == .subscribed)
        #expect(response.locked.isEmpty)

        let board = TodayBoard.merge(response: response, entries: [], media: [])
        #expect(board.locked.isEmpty)
        // No card, and the end-of-board card is unaffected: one live prompt means the board is not
        // finished, so there is no "all caught up" either.
        #expect(AllCaughtUpCard.Mode.forBoard(today: 1, waiting: 0, doneToday: 0, locked: 0) == nil)
    }

    @Test("a free household decodes its locked slots in the order the server sent them")
    func freeHouseholdDecodesLockedSlots() throws {
        let json = Self.preEntitlementPayload
            .replacingOccurrences(of: "\"done_today\": []", with: """
                "done_today": [],
                "access": "free",
                "trial_ends_at": "2026-08-07T00:00:00Z",
                "locked": [
                  { "slot": "mission", "kind_hint": "photo" },
                  { "slot": "mission_b", "kind_hint": "mission" },
                  { "slot": "weekly", "kind_hint": "weekly" }
                ]
                """)

        let response = try decode(json)
        #expect(response.access == .free)
        #expect(response.access.isEntitled == false)
        #expect(response.trialEndsAt != nil)

        let board = TodayBoard.merge(response: response, entries: [], media: [])
        #expect(board.locked.map(\.slot) == ["mission", "mission_b", "weekly"])
        #expect(board.locked.map(\.kindHint) == ["photo", "mission", "weekly"])
        // Order is the server's and is preserved rather than sorted.
        #expect(board.locked.first?.slotKind == .mission)
        #expect(board.locked.first?.kind == .photo)
    }

    /// **A value from a server newer than this build must not lock the board.**
    ///
    /// The failure direction is the whole point: a fourth `access` value has to read as entitled, or
    /// a server release ships a paywall to everyone running an older client.
    @Test("an access value this build does not recognise is treated as entitled")
    func unrecognisedAccessIsEntitled() throws {
        let json = Self.preEntitlementPayload
            .replacingOccurrences(of: "\"done_today\": []", with: """
                "done_today": [], "access": "grandfathered",
                "locked": [ { "slot": "mission", "kind_hint": "photo" } ]
                """)

        let response = try decode(json)
        #expect(response.access == .unrecognised("grandfathered"))
        #expect(response.access.isEntitled, "an unknown access value must never lock a board")

        let board = TodayBoard.merge(response: response, entries: [], media: [])
        #expect(
            board.locked.isEmpty,
            "a server saying both 'entitled' and 'here are locks' contradicts itself; generosity wins"
        )
    }

    /// A `kind_hint` newer than this build renders a neutral card rather than crashing or blanking —
    /// the contract every other constrained value in this app already honours.
    @Test("an unrecognised kind hint decodes to a neutral card, never a crash")
    func unrecognisedKindHintIsNeutral() throws {
        let json = Self.preEntitlementPayload
            .replacingOccurrences(of: "\"done_today\": []", with: """
                "done_today": [], "access": "free",
                "locked": [ { "slot": "seasonal", "kind_hint": "seasonal" } ]
                """)

        let response = try decode(json)
        let locked = try #require(response.locked.first)
        #expect(locked.kind == .other("seasonal"))
        #expect(locked.kind.isRecognised == false)
        #expect(locked.kind.symbolName == "sparkles")
        // It still has words. A neutral card is never a blank one.
        #expect(MembershipCopy.lockedBody(locked.slotKind).isEmpty == false)
        #expect(MembershipCopy.lockedEyebrow(locked.slotKind).isEmpty == false)
    }

    /// `trial_ends_at` is decoded and **read by nothing**. This pins that: a household whose trial
    /// expired long ago but whose `access` still says `trial` is entitled, because the server is the
    /// only thing entitled to do that arithmetic.
    @Test("trial_ends_at in the past does not make a trial household un-entitled")
    func trialEndsAtIsNeverArithmetic() throws {
        let json = Self.preEntitlementPayload
            .replacingOccurrences(of: "\"done_today\": []", with: """
                "done_today": [], "access": "trial",
                "trial_ends_at": "2020-01-01T00:00:00Z",
                "locked": [ { "slot": "mission", "kind_hint": "photo" } ]
                """)

        let response = try decode(json)
        #expect(response.access == .trial)
        #expect(
            response.access.isEntitled,
            "the device must never compute entitlement from a date — D5"
        )

        let board = TodayBoard.merge(response: response, entries: [], media: [])
        #expect(board.locked.isEmpty)
    }

    // MARK: - Against the server's actual bytes

    /// **The two payloads Lane A read off a live server**, not a fixture and not a mock — phase 107,
    /// commit `f2ac83a`, the same child on the same day either side of dropping to free.
    ///
    /// Pinned here because every other decode test in this suite is written against JSON *this* lane
    /// invented, and a client and a server can agree perfectly with each other's imagination.
    @Test("the payloads phase 107 served from a live server decode as this client expects")
    func liveServerPayloadsDecode() throws {
        // In trial: a full board, and `locked` present-but-empty.
        let inTrial = """
            { "date": "2026-08-21", "access": "trial",
              "trial_ends_at": "2026-09-05T02:47:30.847618Z",
              "child": { "id": "\(Self.fixedChildID)", "name": "Milo", "age_months": 50 },
              "today": [], "locked": [], "waiting": [], "done_today": [] }
            """
        let trial = try decode(inTrial)
        #expect(trial.access == .trial)
        #expect(trial.access.isEntitled)
        #expect(trial.locked.isEmpty)
        // A fractional-second UTC timestamp has to parse. It is read by nothing, but a decode
        // failure here would take the whole board down rather than one field.
        #expect(trial.trialEndsAt != nil, "the server's microsecond precision must decode")

        // Free, same child, same day. Note `trial_ends_at` is a **past timestamp, not null** — the
        // trial ended rather than being cleared.
        let afterTrial = """
            { "date": "2026-08-21", "access": "free",
              "trial_ends_at": "2020-01-01T00:00:00Z",
              "child": { "id": "\(Self.fixedChildID)", "name": "Milo", "age_months": 50 },
              "today": [], "waiting": [], "done_today": [],
              "locked": [ { "slot": "mission", "kind_hint": "photo" } ] }
            """
        let free = try decode(afterTrial)
        #expect(free.access == .free)
        #expect(free.access.isEntitled == false)
        #expect(free.locked.count == 1)

        // **The two `free` shapes must be indistinguishable to this client.** A past timestamp and a
        // null one both mean "not in a trial"; the admin Clear button produces the second. Nothing
        // in this app may branch on the difference.
        let cleared = afterTrial.replacingOccurrences(
            of: "\"trial_ends_at\": \"2020-01-01T00:00:00Z\"",
            with: "\"trial_ends_at\": null"
        )
        let clearedResponse = try decode(cleared)
        #expect(clearedResponse.trialEndsAt == nil)
        #expect(clearedResponse.access == free.access)
        #expect(
            TodayBoard.merge(response: clearedResponse, entries: [], media: []).locked.count
                == TodayBoard.merge(response: free, entries: [], media: []).locked.count,
            "a cleared trial and an elapsed one must render identically"
        )
    }

    /// The scheduler's real week, from Lane A's live route. **Four locked rows is the worst case**
    /// and only happens on a Saturday that is also the 1st or the 15th; one row is the common case.
    ///
    /// This is a decode-and-render check across the whole range rather than a claim about the
    /// scheduler, which is the server's business.
    @Test("every locked shape the scheduler can serve renders a card")
    func everyScheduledShapeRenders() throws {
        let week: [[(String, String)]] = [
            [("mission", "photo")],
            [("mission_b", "mission")],
            [("mission", "photo"), ("mission_b", "mission"), ("weekly", "weekly")],
            [("mission", "photo"), ("mission_b", "mission"), ("weekly", "weekly"), ("monthly", "monthly")],
            [("mission", "photo"), ("mission_b", "mission"), ("weekly", "weekly"), ("letter", "letter")],
        ]

        for day in week {
            let locked = day
                .map { "{ \"slot\": \"\($0.0)\", \"kind_hint\": \"\($0.1)\" }" }
                .joined(separator: ",")
            let json = Self.preEntitlementPayload
                .replacingOccurrences(of: "\"done_today\": []", with: """
                    "done_today": [], "access": "free", "locked": [\(locked)]
                    """)

            let board = TodayBoard.merge(response: try decode(json), entries: [], media: [])
            #expect(board.locked.count == day.count)
            for slot in board.locked {
                // Every one has words and a glyph. A card that decoded but could not describe itself
                // is the failure this asserts against.
                #expect(MembershipCopy.lockedEyebrow(slot.slotKind).isEmpty == false)
                #expect(MembershipCopy.lockedBody(slot.slotKind).isEmpty == false)
                #expect(slot.kind.symbolName.isEmpty == false)
            }
        }
    }

    // MARK: - The one-time notice

    /// **The case the obvious implementation gets wrong**, and the reason the rule is a transition
    /// rather than a state: a parent installing on a new phone after their trial already ended.
    @Test("a fresh install whose first response is already free shows no post-trial notice")
    func freshInstallIntoFreeShowsNoNotice() {
        let fresh = MembershipPresentationRecord()
        #expect(
            MembershipPresentation.shouldShowPostTrialNotice(record: fresh, access: .free) == false,
            "a device that never saw the trial must not announce that it ended"
        )
    }

    @Test("the notice fires exactly once, on the flip from trial to free")
    func noticeFiresOnceOnTheFlip() {
        var record = MembershipPresentationRecord()

        // Day one: the server says trial. Nothing to announce; the observation is recorded.
        #expect(MembershipPresentation.shouldShowPostTrialNotice(record: record, access: .trial) == false)
        record = MembershipPresentation.observing(.trial, in: record)
        #expect(record.lastObservedAccess == "trial")

        // Day fifteen: the flip.
        #expect(MembershipPresentation.shouldShowPostTrialNotice(record: record, access: .free))

        // Shown — and spent by being shown, not by being dismissed.
        record.postTrialNoticeShown = true
        record = MembershipPresentation.observing(.free, in: record)

        #expect(
            MembershipPresentation.shouldShowPostTrialNotice(record: record, access: .free) == false,
            "a notice that returns is a nag"
        )
    }

    /// The admin console can set and clear `trial_ends_at`, so one household can go
    /// `trial → free → trial → free` in an afternoon. The first flip announces; the rest do not.
    @Test("a household driven back into trial and out again is not told twice")
    func adminToggleDoesNotRefire() {
        var record = MembershipPresentationRecord()
        record = MembershipPresentation.observing(.trial, in: record)
        #expect(MembershipPresentation.shouldShowPostTrialNotice(record: record, access: .free))

        record.postTrialNoticeShown = true
        record = MembershipPresentation.observing(.free, in: record)
        record = MembershipPresentation.observing(.trial, in: record)

        #expect(MembershipPresentation.shouldShowPostTrialNotice(record: record, access: .free) == false)
    }

    /// A lapsing subscriber is not finishing a trial and must not be told they are.
    @Test("subscribed to free is a lapse, not the end of a trial")
    func lapseDoesNotFireTheTrialNotice() {
        var record = MembershipPresentationRecord()
        record = MembershipPresentation.observing(.subscribed, in: record)
        #expect(
            MembershipPresentation.shouldShowPostTrialNotice(record: record, access: .free) == false
        )
    }

    /// **`.notReported` is not an observation.** A pre-107 server, or a response that lost the
    /// field, must not be able to manufacture a flip out of the next genuine `free`.
    @Test("an absent access value is never recorded as something this device saw")
    func absentAccessIsNotAnObservation() {
        var record = MembershipPresentationRecord()
        record = MembershipPresentation.observing(.trial, in: record)
        let afterAbsent = MembershipPresentation.observing(.notReported, in: record)

        #expect(afterAbsent.lastObservedAccess == "trial", "an absent field must change nothing")
        #expect(MembershipPresentation.observing(.notReported, in: MembershipPresentationRecord())
            .lastObservedAccess == nil)
    }

    // MARK: - The trial welcome, and who must never see it

    /// **The defect this rule exists to prevent, asserted first.**
    ///
    /// A fresh record has `trialWelcomeShown == false`, and the key is new in this build — so a rule
    /// of `!trialWelcomeShown` fires on the first launch after updating for **every existing
    /// install**, including a household that has been paying for months. Telling a subscriber they
    /// are on a free trial that ends is a false statement about money.
    @Test("an existing install that only resumes a session is never shown the trial welcome")
    func resumedSessionIsNeverWelcomed() {
        // What every existing install looks like on the first launch after this build ships.
        let existing = MembershipPresentationRecord()
        #expect(
            MembershipPresentation.shouldShowTrialWelcome(record: existing) == false,
            "a record that has merely never been written is not a sign-in"
        )
    }

    @Test("a sign-in owes the welcome, and showing it spends it")
    func signInOwesTheWelcomeOnce() {
        var record = MembershipPresentationRecord()
        record = MembershipPresentation.owingWelcome(in: record)
        #expect(MembershipPresentation.shouldShowTrialWelcome(record: record))

        record.trialWelcomeShown = true
        record.trialWelcomeOwed = false
        #expect(MembershipPresentation.shouldShowTrialWelcome(record: record) == false)

        // **Signing out and back in does not earn a second one.** The screen explains the two
        // weeks, and the two weeks belong to the household rather than to the session.
        record = MembershipPresentation.owingWelcome(in: record)
        #expect(MembershipPresentation.shouldShowTrialWelcome(record: record) == false)
    }

    /// An invited second guardian joins a household that already exists. They sign in through one of
    /// the four ordinary paths, so without this they would be owed a welcome to two weeks that are
    /// not theirs — on a household that may have been subscribed for a year.
    @Test("arriving by invitation spends the welcome without showing it")
    func invitationDeclinesTheWelcome() {
        var record = MembershipPresentation.owingWelcome(in: MembershipPresentationRecord())
        #expect(MembershipPresentation.shouldShowTrialWelcome(record: record))

        record = MembershipPresentation.decliningWelcome(in: record)
        #expect(MembershipPresentation.shouldShowTrialWelcome(record: record) == false)
        #expect(record.trialWelcomeShown, "declining spends it, so it cannot surface later either")
    }

    @Test("a record that cannot be decoded reads as a fresh one rather than as already-shown")
    func corruptRecordFailsTowardsShowing() {
        let defaults = try! #require(UserDefaults(suiteName: "membership.tests.\(UUID().uuidString)"))
        defaults.set(Data("not json".utf8), forKey: "membership.presentation")
        let store = UserDefaultsMembershipPresentationStore(defaults: defaults, key: "membership.presentation")

        let record = store.load()
        #expect(record.trialWelcomeShown == false)
        #expect(record.postTrialNoticeShown == false)
        #expect(record.lastObservedAccess == nil)
    }

    // MARK: - The notice, driven through the model that actually decides it

    /// **`TodayModel.observe(_:)` is the only code that decides whether the notice appears**, and it
    /// was previously asserted only through its pure helpers. This drives the real model against a
    /// scripted network, twice, with the store carried between the two loads — which is the shape of
    /// the actual bug: an observation recorded on one load being read on the next.
    @MainActor
    @Test("the model announces the trial's end exactly once, across two real loads")
    func modelFiresTheNoticeOnceAcrossLoads() async throws {
        let store = InMemoryMembershipPresentationStore()
        let child = UUID()

        func model(access: String, locked: String) -> TodayModel {
            let performer = StubPerformer()
            let json = """
                { "date": "2026-08-21", "access": "\(access)",
                  "child": { "id": "\(child.uuidString)", "name": "Milo", "age_months": 50 },
                  "today": [], "waiting": [], "done_today": [], "locked": [\(locked)] }
                """
            performer.on("/today") { _ in (Data(json.utf8), 200) }
            return TodayModel(
                childId: child,
                api: APIClient(
                    baseURL: URL(string: "http://localhost:8000/")!,
                    performer: performer,
                    tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
                ),
                presentation: store
            )
        }

        // Day one, in trial. Nothing to announce — and the observation is what makes day fifteen work.
        let inTrial = model(access: "trial", locked: "")
        await inTrial.load()
        #expect(inTrial.membershipNotice == nil, "a household still in its trial is told nothing")
        #expect(store.load().lastObservedAccess == "trial")

        // Day fifteen, on the same device. The flip.
        let afterTrial = model(access: "free", locked: "{ \"slot\": \"mission\", \"kind_hint\": \"photo\" }")
        await afterTrial.load()
        #expect(afterTrial.membershipNotice == MembershipCopy.postTrialNotice)
        #expect(store.load().postTrialNoticeShown, "seeing it spends it, not dismissing it")

        // Day sixteen. Never again.
        let later = model(access: "free", locked: "{ \"slot\": \"mission\", \"kind_hint\": \"photo\" }")
        await later.load()
        #expect(later.membershipNotice == nil, "a notice that returns is a nag")
    }

    /// A network failure must not be recorded as an observation. If it were, the next genuine `free`
    /// would look like a flip from something and the notice would fire on a household that never
    /// had a trial end.
    @MainActor
    @Test("a failed load records no observation")
    func failedLoadRecordsNothing() async throws {
        let store = InMemoryMembershipPresentationStore()
        let performer = StubPerformer()
        performer.on("/today") { _ in (Data("{}".utf8), 500) }

        let model = TodayModel(
            childId: UUID(),
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            presentation: store
        )
        await model.load()

        #expect(store.load().lastObservedAccess == nil, "a request that failed saw nothing")
        #expect(model.membershipNotice == nil)
    }

    // MARK: - The offer timeout

    /// **A spinner with no terminal state, closed.**
    ///
    /// `Product.products(for:)` has no timeout of its own and `URLSession.shared` is unconfigured
    /// here, so a StoreKit hang left the sheet reading *"Loading the options"* forever. That was
    /// survivable while a successful fetch was the expected path; it is not now that
    /// **an unavailable fetch is the expected path** — no subscription product exists in App Store
    /// Connect, so the spinner would be the ordinary experience.
    ///
    /// The injection points existed and nothing used them, which is how a guard rots.
    @MainActor
    @Test("a hung store still gives the sheet a terminal state")
    func offerTimeoutTerminates() async {
        let store = HangingStore()
        let model = SubscriptionModel(
            readHousehold: { .sample(tier: "free") },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            // A deadline that has already passed, so the assertion is about *what* happens rather
            // than about winning a race on a loaded machine.
            offerTimeout: .zero,
            offerSleep: { _ in }
        )

        await model.load()

        // **`load()` does await the hung store — deliberately.** The requirement is that the sheet
        // stops spinning, not that the request is abandoned; a StoreKit call that ignores
        // cancellation cannot be abandoned. What matters is that a parent is never left on
        // "Loading the options" with nothing to read.
        guard case .unavailable(.products) = model.phase else {
            Issue.record("a hung product fetch must end in .products, not hold the spinner")
            return
        }
        // **The household is not blamed for the store's silence.** It answered.
        #expect(model.household != nil)
        #expect(model.canBuy == false)
    }

    /// **The deadline has to move `phase` while the store is still hanging**, or it is not a
    /// terminal state, only a slower one. Asserted by observing the phase *before* the store has
    /// finished, which is the whole claim and the thing a wall-clock check cannot make.
    @MainActor
    @Test("the spinner ends before the store does")
    func theSpinnerEndsBeforeTheStoreDoes() async {
        let store = HangingStore()
        let model = SubscriptionModel(
            readHousehold: { .sample(tier: "free") },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            offerTimeout: .zero,
            offerSleep: { _ in }
        )

        let loading = Task { await model.load() }

        // Poll for the phase to move, rather than assuming how long the deadline takes to be
        // scheduled. Bounded well under `HangingStore`'s three seconds.
        var settled = false
        for _ in 0..<100 {
            if case .unavailable(.products) = model.phase { settled = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(settled, "the phase never left .loading while the store hung")
        #expect(
            await store.didFinish == false,
            "the store finished first, so this proves nothing about the deadline"
        )

        await loading.value
    }

    /// The other half, and the regression this phase actually shipped and had to fix: reusing
    /// `confirmationSleep` for the timeout made it resolve instantly, win every race, and turn every
    /// load in the suite into `.unavailable`. A working store must still win.
    @MainActor
    @Test("a store that answers beats the timeout")
    func offerTimeoutDoesNotPreemptAWorkingStore() async {
        let model = SubscriptionModel(
            readHousehold: { .sample(tier: "free") },
            store: InstantStore(),
            confirmationSchedule: [],
            // Instant, exactly as `makeModel` stubs it — the shape that broke five tests.
            confirmationSleep: { _ in },
            offerTimeout: .seconds(30),
            offerSleep: { try await Task.sleep(for: $0) }
        )

        await model.load()

        guard case .ready = model.phase else {
            Issue.record("a store that answered should have produced an offer")
            return
        }
    }

    // MARK: - The end of the board

    /// *"Nothing waiting. Today's prompts arrive in the morning"* under four locked cards is a flat
    /// contradiction on one screen: the prompts **have** arrived.
    @Test("a locked board with nothing done gets no end-of-board card")
    @MainActor
    func lockedBoardSuppressesNothingYet() {
        #expect(AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 0, doneToday: 0, locked: 0) == .nothingYet)
        #expect(AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 0, doneToday: 0, locked: 3) == nil)
    }

    /// **And the other half, which is the one worth defending.** A free parent who answered today's
    /// question has finished everything they were offered, and withholding the acknowledgement
    /// because they did not pay would be the meanest available reading.
    @Test("all caught up survives a locked board when something was actually done")
    @MainActor
    func caughtUpSurvivesLocks() {
        #expect(
            AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 0, doneToday: 1, locked: 3)
                == .caughtUp(doneToday: 1)
        )
    }

    // MARK: - The copy

    /// The copy file keeps its banned list explicit *"so a review can grep for them"*. This is that
    /// grep, run against every string the phase can put on a screen.
    ///
    /// **`Locked` is not in the assertion**, and the copy file says why: it is banned as a
    /// user-visible *label*, while *"the visual state may still be called locked in code"* — which
    /// is what keeps `LockedPromptCard` and `LockedSlot` legitimate names.
    @Test("no banned word reaches a parent")
    func noBannedWordShipsInUserVisibleCopy() {
        // **Both lists come from the shipped constants**, so neither can drift from what the app
        // actually says or from what the copy file actually bans. The previous version of this test
        // duplicated the phrases inline and enforced 8 of the 11 — a guard that agreed with itself.
        #expect(MembershipCopy.bannedPhrases.count == 11, "the copy file's §4 lists eleven")
        #expect(MembershipCopy.allUserVisibleStrings.count > 30, "the string list stopped collecting")

        for string in MembershipCopy.allUserVisibleStrings {
            let lowered = string.lowercased()
            for banned in MembershipCopy.bannedPhrases {
                // `Pro` is a whole word, not a fragment: "Pro" must not match "**pro**mpt", and
                // "Only X left" is a shape rather than a literal, so it is matched on "only".
                let needle = banned.lowercased()
                let hit: Bool
                switch needle {
                case "pro":
                    hit = lowered.split(whereSeparator: { !$0.isLetter }).contains("pro")
                case "only x left":
                    hit = lowered.contains("only") && lowered.contains("left")
                default:
                    hit = lowered.contains(needle)
                }
                #expect(!hit, "\"\(string)\" contains the banned phrase \"\(banned)\"")
            }
        }
    }

    /// **The guard above only means something if it can fail.** A banned phrase planted in a real
    /// shipped string must be caught, which is what proves the two lists are actually connected —
    /// the previous version would have passed with `Only X left`, `Your archive will be` and `Pro`
    /// absent from its inline copy.
    @Test("the banned-word guard actually catches a planted phrase")
    func theBannedWordGuardCanFail() {
        for banned in MembershipCopy.bannedPhrases {
            let planted = "Become a member and \(banned) today"
            let lowered = planted.lowercased()
            let needle = banned.lowercased()
            let hit: Bool
            switch needle {
            case "pro":
                hit = lowered.split(whereSeparator: { !$0.isLetter }).contains("pro")
            case "only x left":
                hit = lowered.contains("only") && lowered.contains("left")
            default:
                hit = lowered.contains(needle)
            }
            #expect(hit, "the guard would not have caught \"\(banned)\"")
        }
    }

    /// **Every locked string renders for a real child**, which is what the pronoun decision is for.
    ///
    /// A token that survives substitution reaches a parent as a literal `{them}` — `PromptTokens`
    /// renders an unknown token verbatim rather than throwing, so a typo here would be silent.
    @Test("every locked string renders with no token left standing")
    func lockedStringsRenderCleanly() {
        let subjects = [
            PromptSubject(name: "Milo", pronouns: .heHim),
            PromptSubject(name: "Ada", pronouns: .sheHer),
            PromptSubject(name: "Sam", pronouns: .theyThem),
            PromptSubject(name: "Kit", pronouns: nil),
            .unknown,
        ]
        let slots: [Slot] = [.mission, .missionB, .weekly, .monthly, .letter, .unknown("seasonal")]

        for subject in subjects {
            for slot in slots {
                for raw in [MembershipCopy.lockedEyebrow(slot), MembershipCopy.lockedBody(slot)] {
                    let rendered = PromptTokens.render(raw, for: subject)
                    #expect(!rendered.contains("{"), "\(rendered) still carries a token")
                    #expect(!rendered.contains("}"), "\(rendered) still carries a token")
                }
            }
        }
    }

    /// **The owner's copy, byte for byte, for the child it was written for.**
    ///
    /// This is the assertion that makes the pronoun transformation defensible: tokenising did not
    /// rewrite the sentences, it only made them correct for children other than Milo.
    @Test("a he/him child reads the owner's copy verbatim")
    func heHimRendersTheOwnersCopyVerbatim() {
        let milo = PromptSubject(name: "Milo", pronouns: .heHim)

        #expect(
            PromptTokens.render(MembershipCopy.lockedBody(.mission), for: milo)
                == "A picture of him, and the reason you took it."
        )
        #expect(
            PromptTokens.render(MembershipCopy.lockedBody(.missionB), for: milo)
                == "His voice, a video, or something to do together."
        )
        #expect(
            PromptTokens.render(MembershipCopy.lockedBody(.weekly), for: milo)
                == "A bigger one, once a week."
        )
        #expect(
            PromptTokens.render(MembershipCopy.lockedBody(.monthly), for: milo)
                == "How much of him has changed since last month."
        )
        // **The one string that is not byte-identical**, and the deviation is recorded rather than
        // hidden: the copy file writes "until he's old enough" and the token table has no contracted
        // form. Inventing a `{they_is}` token is exactly what the copy file forbids.
        #expect(
            PromptTokens.render(MembershipCopy.lockedBody(.letter), for: milo)
                == "Sealed until he is old enough to read it."
        )
    }

    /// The sheet renders against **no child**, which is they/them by construction — a household is
    /// not a child, and in a household with a boy and a girl any other choice is wrong for one.
    @Test("the membership sheet's copy is neutral because it has no child to read")
    func sheetCopyIsNeutral() {
        let rendered = MembershipCopy.adds.map { PromptTokens.render($0, for: .unknown) }
        #expect(rendered.contains { $0.contains("their voice") })
        #expect(rendered.contains { $0.contains("until they are old enough") })
        #expect(rendered.contains { $0.contains("Their other parent") })
        for line in rendered {
            #expect(!line.lowercased().contains(" his "))
            #expect(!line.lowercased().hasPrefix("his "))
        }
    }
}

/// A store that never answers, and **cannot be cancelled into answering.**
///
/// The first version of this double used `Task.sleep`, which *is* cancellable — so it proved the
/// easy case and said nothing about the one that matters. `SubscriptionStore.loadOffer()` awaits
/// `Product.SubscriptionInfo.isEligibleForIntroOffer(for:)`, which is `async` and **not throwing**
/// and therefore cannot report cancellation at all. A continuation resumed from a timer models that
/// exactly: nothing anyone does to this task makes it finish sooner.
///
/// With the old task-group implementation this test hung for the full delay and then failed. That is
/// the point of it.
private actor HangingStore: SubscriptionPurchasing {
    /// Whether the hung call has finished yet. **This is what the test asserts on**, rather than a
    /// stopwatch: "did `load()` return before the store did" is the actual question, it is causal
    /// rather than temporal, and it cannot go flaky when 1100 other tests are running in parallel.
    private(set) var didFinish = false

    func loadOffer() async throws -> SubscriptionOffer {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                continuation.resume()
            }
        }
        didFinish = true
        throw SubscriptionStoreError.productsUnavailable
    }

    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        .cancelled
    }

    func restore() async throws {}
}

/// A store that answers immediately, to prove the timeout does not pre-empt a working one.
private actor InstantStore: SubscriptionPurchasing {
    func loadOffer() async throws -> SubscriptionOffer { .preview }
    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        .purchased
    }
    func restore() async throws {}
}
