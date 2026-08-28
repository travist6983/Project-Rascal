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

    /// **A slot the server listed twice must draw one card, not two.**
    ///
    /// `ForEach` keys these on `slot`, and duplicate ids in a `List` are undefined behaviour rather
    /// than merely a duplicated row. `TodayBoard.merge` already de-duplicates `done_today` on the
    /// same reasoning, and its comment says why: *"a card appearing twice is the most visible
    /// possible bug and costs one line to rule out."*
    @Test("a slot the server repeated draws one card")
    func duplicateLockedSlotsAreCollapsed() throws {
        let json = Self.preEntitlementPayload
            .replacingOccurrences(of: "\"done_today\": []", with: """
                "done_today": [], "access": "free",
                "locked": [
                  { "slot": "mission", "kind_hint": "photo" },
                  { "slot": "mission", "kind_hint": "photo" },
                  { "slot": "weekly", "kind_hint": "weekly" }
                ]
                """)

        let board = TodayBoard.merge(response: try decode(json), entries: [], media: [])
        #expect(board.locked.map(\.slot) == ["mission", "weekly"])
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
    func corruptRecordFailsTowardsShowing() throws {
        // **A named suite that is removed afterwards.** The first version minted a fresh
        // `UUID`-named suite on every run and never cleaned it up, so each pass left a plist behind
        // in the simulator; and it used `try!` on the initialiser, which traps the whole test
        // process rather than failing one test if the suite cannot be opened.
        let name = "membership.presentation.tests"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let key = "membership.presentation"
        defaults.set(Data("not json".utf8), forKey: key)
        let store = UserDefaultsMembershipPresentationStore(defaults: defaults, key: key)

        let record = store.load()
        #expect(record.trialWelcomeShown == false)
        #expect(record.trialWelcomeOwed == false)
        #expect(record.postTrialNoticeShown == false)
        #expect(record.lastObservedAccess == nil)
    }

    /// **The banned-word guard covers `MembershipCopy`. This covers everywhere else.**
    ///
    /// The sheet still renders strings authored at the call site — `"Loading the options"`,
    /// `"Restore a purchase"`, the purchase-outcome sentences — which phase 37b wrote and this phase
    /// did not move. None of them contains a banned word today, and nothing would notice if a later
    /// edit introduced one.
    ///
    /// A source scan rather than a runtime check, which is the idiom this suite already uses for
    /// `noCurrencyLiterals`: it sees strings no test path renders, and it sees them in files nobody
    /// thought to add to a list.
    @Test("no banned word appears in any string literal in the surfaces this phase ships")
    func noBannedWordInAnySurfaceSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rascal")

        let files = [
            "Subscription/PaywallSheet.swift",
            "Subscription/SubscriptionSection.swift",
            // **Added by phase 126, and it was a real gap rather than tidying.** The two sentences a
            // restore leaves behind — the not-found notice and `restoreFound` — are authored here,
            // render on the Membership card, and were in no file this list named. A guard that
            // covers the views and not the model that supplies their words covers half the surface.
            "Subscription/SubscriptionModel.swift",
            "Today/LockedPromptCard.swift",
            "Today/TodayBoardView.swift",
            "Onboarding/TrialWelcomeScreen.swift",
            "DesignSystem/Notice.swift",
        ].map { root.appendingPathComponent($0) }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.isEmpty, "\(file.lastPathComponent) moved and this test stopped looking")

            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Comments are where these words are allowed to be discussed, and this phase
                // discusses them at length.
                if code.hasPrefix("//") || code.hasPrefix("///") || code.hasPrefix("*") { continue }

                for match in code.matches(of: /"([^"]*)"/) {
                    let literal = String(match.output.1)
                    for banned in MembershipCopy.bannedPhrases
                    where MembershipCopy.contains(banned, in: literal) {
                        let where_ = "\(file.lastPathComponent):\(index + 1)"
                        Issue.record("banned phrase \"\(banned)\" in \"\(literal)\" at \(where_)")
                    }
                }
            }
        }
    }

    /// **The population the local flag alone could not exclude: a subscriber signing in on a new
    /// phone.**
    ///
    /// `trialWelcomeOwed` is set by every successful sign-in, which correctly excludes an existing
    /// install resuming a session and — through `declineTrialWelcome()` — an invited guardian. It
    /// cannot exclude a household that is already paying, because the client does not know the tier
    /// at sign-in. Telling that parent *"Two weeks, everything open. No card, nothing to cancel."*
    /// is a false statement about money on their first screen.
    ///
    /// Driven through the real `OnboardingSession` against a scripted network, because the defect is
    /// in the **wiring** — which method asks the server, and what it does with the answer — and a
    /// test of the pure rules is structurally blind to that.
    @MainActor
    @Test("a subscribed household signing in on a new device is not welcomed to a trial")
    func aSubscriberIsNotWelcomedToATrial() async {
        let store = InMemoryMembershipPresentationStore(
            MembershipPresentation.owingWelcome(in: MembershipPresentationRecord())
        )
        let performer = StubPerformer()
        performer.on("/families/me") { _ in (Data(Self.familyJSON(tier: "subscribed", access: "subscribed").utf8), 200) }
        let session = onboardingSession(performer, tokens: signedIn, membership: store)

        #expect(await session.owesTrialWelcome() == false, "a paying household must not be shown a trial")
        #expect(
            store.load().trialWelcomeShown,
            "one confirmed answer settles it — a subscriber should not be asked again later either"
        )
    }

    /// The other half, so the guard above cannot be satisfied by never showing the screen at all.
    @MainActor
    @Test("a free household signing in is still owed the two weeks")
    func aFreeHouseholdIsStillWelcomed() async {
        let store = InMemoryMembershipPresentationStore(
            MembershipPresentation.owingWelcome(in: MembershipPresentationRecord())
        )
        let performer = StubPerformer()
        performer.on("/families/me") { _ in (Data(Self.familyJSON(tier: "free", access: "trial").utf8), 200) }
        let session = onboardingSession(performer, tokens: signedIn, membership: store)

        #expect(await session.owesTrialWelcome())
        #expect(store.load().trialWelcomeShown == false, "asking is not showing")
    }

    /// **The case `tier` could never have seen.**
    ///
    /// A returning parent signing in on a new phone, whose fortnight ended long ago, is
    /// `tier: "free"` — identical to a household three days into its trial. Gating on
    /// `isSubscribed` would have told them *"Two weeks, everything open. No card, nothing to
    /// cancel."* `access` is the only field that distinguishes them, and phase 107 already returns
    /// it on `/families/me`.
    @MainActor
    @Test("a free household whose trial has already ended is not welcomed to a new one")
    func aLapsedHouseholdIsNotWelcomedAgain() async {
        let store = InMemoryMembershipPresentationStore(
            MembershipPresentation.owingWelcome(in: MembershipPresentationRecord())
        )
        let performer = StubPerformer()
        performer.on("/families/me") { _ in
            (Data(Self.familyJSON(tier: "free", access: "free").utf8), 200)
        }
        let session = onboardingSession(performer, tokens: signedIn, membership: store)

        #expect(await session.owesTrialWelcome() == false)
        #expect(store.load().trialWelcomeShown, "settled — they should not be asked again either")
    }

    /// A server that does not report `access` cannot confirm a trial, so nothing is shown — **and
    /// nothing is spent**, so a later launch against a server that does report it asks again.
    @MainActor
    @Test("a server that does not report access neither welcomes nor settles")
    func aServerWithoutAccessDefersTheWelcome() async {
        let store = InMemoryMembershipPresentationStore(
            MembershipPresentation.owingWelcome(in: MembershipPresentationRecord())
        )
        let performer = StubPerformer()
        performer.on("/families/me") { _ in
            let json = """
                { "family_id": "33333333-3333-3333-3333-333333333333", "tier": "free",
                  "guardians": [], "pending_invites": [] }
                """
            return (Data(json.utf8), 200)
        }
        let session = onboardingSession(performer, tokens: signedIn, membership: store)

        #expect(await session.owesTrialWelcome() == false)
        #expect(store.load().trialWelcomeOwed, "the flag must survive so a later launch retries")
        #expect(store.load().trialWelcomeShown == false)
    }

    /// **Fails closed, and does not spend the flag.** A household we could not ask about is not
    /// shown the screen — but the next launch tries again rather than either lying to a subscriber
    /// or swallowing the welcome for good.
    @MainActor
    @Test("a household the server cannot confirm is not welcomed, and is asked again later")
    func anUnreachableHouseholdIsNotWelcomedYet() async {
        let store = InMemoryMembershipPresentationStore(
            MembershipPresentation.owingWelcome(in: MembershipPresentationRecord())
        )
        let performer = StubPerformer()
        performer.on("/families/me") { _ in (Data("{}".utf8), 500) }
        let session = onboardingSession(performer, tokens: signedIn, membership: store)

        #expect(await session.owesTrialWelcome() == false)
        #expect(store.load().trialWelcomeOwed, "the flag must survive so the next launch retries")
        #expect(store.load().trialWelcomeShown == false)
    }

    /// A `/families/me` body good enough for `FamilySummary`.
    private static func familyJSON(tier: String, access: String) -> String {
        """
        { "family_id": "33333333-3333-3333-3333-333333333333", "tier": "\(tier)",
          "access": "\(access)", "guardians": [], "pending_invites": [] }
        """
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
    /// **The deadline must move `phase` while the store is still hanging**, or it is not a terminal
    /// state, only a slower one.
    ///
    /// Every assertion here is causal. `HangingStore` finishes only when this test resumes it, so
    /// `didFinish == false` is guaranteed rather than raced — which is what the previous version of
    /// this test claimed and could not deliver.
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

        var settled = false
        for _ in 0..<400 {
            if case .unavailable(.products) = model.phase { settled = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(settled, "the phase never left .loading while the store hung")
        #expect(
            await store.didFinish == false,
            "the store cannot have finished — nothing has released it"
        )
        // Nothing may be bought while there is no offer.
        #expect(model.canBuy == false)

        // **The household is published while the store is still hanging, and this is the only
        // assertion in the suite that says so.**
        //
        // It used to be asserted *after* `release()`, with a comment explaining that `household`
        // "is assigned after the join" and therefore could not have landed yet. That comment
        // described the code accurately when it was written and was made false an hour later, by
        // the change that publishes the household as soon as it arrives — which exists to stop an
        // abandoned load writing its stale summary over a newer one. Asserting it here is what
        // pins that change; asserting it after the release proved only that a completed load
        // eventually publishes something.
        var published = false
        for _ in 0..<400 {
            if model.household != nil { published = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(published, "the household waited on a store that has nothing to do with it")
        #expect(await store.didFinish == false, "and it landed before the store did")

        await store.release()
        await loading.value

        // The terminal state survives the hung call finally returning.
        guard case .unavailable(.products) = model.phase else {
            Issue.record("a late failure should not have moved the phase off .products")
            return
        }
    }

    /// **The deadline has to free the model, not only the screen.**
    ///
    /// `isLoading` is released by a `defer`, so a `load()` suspended on a hung store held it for the
    /// whole hang. The deadline moved `phase` and the sheet said something true — but the next
    /// `load()`, from a locked card or from Settings, early-returned in silence. Any hang longer
    /// than the deadline opened a window where membership was unbuyable **and every retry was
    /// ignored**, app-wide, because this is the single instance on `RootView`.
    ///
    /// Asserted by counting the store's calls, which is the only way to tell a retry that ran from
    /// one that was swallowed: `phase` is `.unavailable(.products)` either way.
    @MainActor
    @Test("a retry after the deadline is actually attempted, not swallowed")
    func aRetryAfterTheDeadlineIsAttempted() async {
        let store = HangingStore()
        let model = SubscriptionModel(
            readHousehold: { .sample(tier: "free") },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            offerTimeout: .zero,
            offerSleep: { _ in }
        )

        let first = Task { await model.load() }

        for _ in 0..<400 {
            if case .unavailable(.products) = model.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The parent reopens the sheet.
        let second = Task { await model.load() }
        for _ in 0..<400 where await store.attempts < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            await store.attempts >= 2,
            "the second load never reached the store — the re-entry guard swallowed it"
        )

        await store.release()
        await first.value
        await second.value
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

    /// **A load the deadline gave up on must not overwrite a newer one.**
    ///
    /// This is what `loadGeneration` is for, and nothing exercised it: the two timeout tests both
    /// end with a single load in flight. Here the first load hangs past its deadline, a second runs
    /// to completion and finds an offer, and only then does the first return.
    @MainActor
    @Test("a load abandoned at the deadline cannot overwrite a newer one")
    func aStaleLoadCannotOverwriteANewerOne() async {
        let store = HangThenAnswerStore()
        let model = SubscriptionModel(
            readHousehold: { .sample(tier: "free") },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            offerTimeout: .zero,
            offerSleep: { _ in }
        )

        let first = Task { await model.load() }
        for _ in 0..<400 {
            if case .unavailable(.products) = model.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The second load answers, and its answer is the current one.
        await model.load()
        guard case .ready = model.phase else {
            Issue.record("the second load should have found an offer")
            return
        }

        // Now let the abandoned first load finish. It reports *no* offer, and if it were allowed to
        // speak it would replace a working paywall with `.unavailable`.
        await store.release()
        await first.value

        guard case .ready = model.phase else {
            Issue.record("a stale load overwrote the newer answer")
            return
        }
    }

    /// **`.products` must not re-run a full load on every foreground.**
    ///
    /// It is the ordinary state — no subscription product exists in App Store Connect — so the old
    /// `if case .unavailable` would have re-run `Product.products(for:)` every time the app came
    /// forward, forever, for an answer that cannot change until somebody creates a product.
    /// `.household` is a genuine transient failure and does retry.
    @MainActor
    @Test("a foreground re-reads the household but does not re-run a settled product load")
    func foregroundRetriesOnlyTheHouseholdFailure() async {
        let store = HangThenAnswerStore()
        let model = SubscriptionModel(
            readHousehold: { .sample(tier: "free") },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            offerTimeout: .zero,
            offerSleep: { _ in }
        )

        let first = Task { await model.load() }
        for _ in 0..<400 {
            if case .unavailable(.products) = model.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await store.release()
        await first.value

        let before = await store.attempts
        await model.refreshHousehold()
        #expect(
            await store.attempts == before,
            "a foreground re-ran the product fetch for an answer that cannot have changed"
        )
    }

    /// **The mirror, so the rule above cannot be satisfied by never retrying anything.**
    ///
    /// `.household` is a genuine transient failure and a foreground *must* re-run the load. A guard
    /// that only asserts the negative half is satisfied by deleting the retry entirely.
    @MainActor
    @Test("a foreground does re-run a load that failed on the household")
    func foregroundRetriesTheHouseholdFailure() async {
        let store = InstantStore()
        let attempts = FailureCount()

        let model = SubscriptionModel(
            readHousehold: {
                // Fails once, then answers — so the first load lands in `.unavailable(.household)`.
                if await attempts.next() == 1 { throw SubscriptionStoreError.productsUnavailable }
                return .sample(tier: "free")
            },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            offerTimeout: .seconds(30),
            offerSleep: { try await Task.sleep(for: $0) }
        )

        await model.load()
        guard case .unavailable(.household) = model.phase else {
            Issue.record("a household that did not answer should be the household's failure")
            return
        }

        await model.refreshHousehold()
        guard case .ready = model.phase else {
            Issue.record("a foreground did not retry a household failure that would now succeed")
            return
        }
    }

    // MARK: - A failed purchase, and a household that has since paid

    /// **A subscribed household must not coexist with `purchase == .failed`.**
    ///
    /// That pair is what let an enabled "Become a member" render for somebody who already had one:
    /// the sheet gated the retry on the phase, `buy()` guards on `canBuy`, and `canBuy` is false for
    /// a subscriber — so the button was live and inert, which is worse than the greyed one it
    /// replaced.
    ///
    /// It is reachable with no transaction on this device: the second guardian buys, or the App
    /// Store webhook lands from another Apple ID, so nothing bumps `transactionRevision` and no
    /// foreground happens. Reopening the sheet runs `load()` — and `load()` used to publish the
    /// subscribed household while leaving `purchase` alone, which `refreshHousehold()`, `restore()`
    /// and `confirm()` all knew not to do.
    @MainActor
    @Test("a load settles a failed purchase the server has since answered")
    func aLoadSettlesAFailedPurchaseAgainstTheHousehold() async {
        let reads = FailureCount()
        let model = SubscriptionModel(
            // Free on the first read, subscribed on every one after — somebody else paid.
            readHousehold: {
                await reads.next() == 1 ? .sample(tier: "free") : .sample(tier: "subscribed")
            },
            store: FailingPurchaseStore(),
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            offerTimeout: .seconds(30),
            offerSleep: { try await Task.sleep(for: $0) }
        )

        // Reach `.failed` the way a parent would.
        await model.load()
        await model.buy()
        guard case .failed = model.purchase else {
            Issue.record("the store was supposed to refuse the purchase")
            return
        }

        // The sheet is reopened, which is a `load()` and nothing else.
        await model.load()

        #expect(
            model.purchase == .subscribed,
            "a load left a failed purchase standing over a subscribed household"
        )
        #expect(model.canBuy == false)
    }

    // MARK: - A throw that lands after the server has already granted

    /// **The server's answer outranks a local throw, in both directions.**
    ///
    /// `refreshHousehold()` has always handled one direction — a purchase that threw and then
    /// turned out to have gone through stops claiming failure the moment the server disagrees.
    /// This is the same collision arriving in the other order, and it went the wrong way.
    ///
    /// `buy()` awaits `store.purchase` on the main actor, and leaving for Apple's payment sheet is
    /// exactly what makes the app background and then foreground — which runs the sheet's
    /// `scenePhase` handler, and `refreshHousehold()` with it. So a household that goes subscribed
    /// mid-purchase is the ordinary case, not a contrived one. The awaited call then threw and
    /// `purchase = .failed` wrote straight over the granted entitlement, telling a parent the
    /// purchase failed on a device that had already been told otherwise.
    @MainActor
    @Test("a throw after the server has granted does not report a failure")
    func aLateThrowDoesNotOverwriteAGrantedEntitlement() async {
        let store = HangingPurchaseStore()
        let granted = GrantFlag()

        let model = SubscriptionModel(
            readHousehold: {
                await granted.isSet ? .sample(tier: "subscribed") : .sample(tier: "free")
            },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in },
            offerTimeout: .seconds(30),
            offerSleep: { try await Task.sleep(for: $0) }
        )

        await model.load()
        #expect(model.canBuy, "a free household with an offer should be able to buy")

        // The parent taps Become a member and Apple's sheet comes up.
        let buying = Task { await model.buy() }
        var reached = false
        for _ in 0..<400 {
            if model.purchase == .purchasing { reached = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(reached, "the purchase never started")

        // They come back to the app. The server has granted meanwhile — the second guardian paid,
        // or the App Store webhook landed — and the foreground read picks it up.
        await granted.set()
        await model.refreshHousehold()
        #expect(model.purchase == .subscribed)

        // Only now does Apple's call fail.
        await store.release()
        await buying.value

        #expect(
            model.purchase == .subscribed,
            "a local throw overwrote an entitlement the server had already granted"
        )
        if case .failed = model.purchase {
            Issue.record("a subscribed household was told its purchase failed")
        }
    }

    // MARK: - The Today heading over a locked board

    /// **The state a free household is in for most of every day**, and the one that shipped wrong:
    /// the heading rendered only when `today` was non-empty, so the moment the daily question was
    /// answered the locked cards were left floating above *Waiting* with nothing naming them.
    ///
    /// A property rather than a condition in the view, because `TodayBoardView` is a `List` —
    /// `ImageRenderer` will not rasterize one and there is no UI test target, so the rule was
    /// expressible nowhere.
    @MainActor
    @Test("the Today heading survives the question being answered on a locked board")
    func theTodayHeadingCoversLockedCards() {
        let locked = [LockedSlot(slot: "mission", kindHint: "photo")]

        // The ordinary free morning: one live question above one lock.
        #expect(TodayPreview.board(today: [TodayPreview.item(.question)], locked: locked).showsTodaySection)

        // **The same board, after the question is answered.** `merge` routes a done item out of
        // `today`, so this is `today == [] && locked != []` — the case that shipped headerless.
        #expect(TodayPreview.board(done: [TodayPreview.item(.question, done: true)], locked: locked).showsTodaySection)

        // An entitled board with live prompts and no locks still gets one.
        #expect(TodayPreview.board(today: [TodayPreview.item(.photo)]).showsTodaySection)

        // And a board with neither does not — a heading over nothing is furniture.
        #expect(TodayPreview.board(done: [TodayPreview.item(.question, done: true)]).showsTodaySection == false)
        #expect(TodayPreview.board().showsTodaySection == false)
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
        // **Both lists and the matcher are the shipped ones**, so none of the three can drift from
        // what the app says, what the copy file bans, or how the ban is meant to be read.
        #expect(MembershipCopy.bannedPhrases.count == 11, "the copy file's §4 lists eleven")
        #expect(MembershipCopy.allUserVisibleStrings.count > 30, "the string list stopped collecting")

        for string in MembershipCopy.allUserVisibleStrings {
            for banned in MembershipCopy.bannedPhrases {
                #expect(
                    !MembershipCopy.contains(banned, in: string),
                    "\"\(string)\" contains the banned phrase \"\(banned)\""
                )
            }
        }
    }

    /// **The guard above only means something if it can fail**, and this proves it against the
    /// *production* matcher rather than a copy of it. An earlier version of this test carried its
    /// own `switch` and therefore proved only that the test file worked.
    @Test("the banned-word guard catches a phrase planted in a real string")
    func theBannedWordGuardCanFail() {
        for banned in MembershipCopy.bannedPhrases {
            let planted = "Become a member and \(banned) today"
            #expect(
                MembershipCopy.contains(banned, in: planted),
                "the guard would not have caught \"\(banned)\""
            )
        }
    }

    /// A typographic apostrophe is the same word. A ban that only recognises `'` is one somebody
    /// evades by pasting prose from a document.
    @Test("the banned-word guard reads both apostrophes as the same character")
    func theBannedWordGuardNormalisesApostrophes() {
        #expect(MembershipCopy.contains("Don't lose", in: "Don\u{2019}t lose your archive"))
        #expect(MembershipCopy.contains("You've missed", in: "You\u{2019}ve missed four missions"))
        // And the plain spelling still matches, so normalising did not break the ordinary case.
        #expect(MembershipCopy.contains("Don't lose", in: "Don't lose your archive"))
    }

    /// And that it does **not** fire on the near-misses the rule deliberately allows — a matcher
    /// that flags everything is as useless as one that flags nothing.
    @Test("the banned-word guard does not fire on words that merely contain a banned one")
    func theBannedWordGuardIsNotOverEager() {
        #expect(MembershipCopy.contains("Pro", in: "Today's photo mission prompt") == false)
        #expect(MembershipCopy.contains("Only X left", in: "The only thing left is the question"))
        #expect(MembershipCopy.contains("Only X left", in: "Only the daily question is free") == false)
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

/// A store that never answers, **cannot be cancelled into answering, and finishes only when the test
/// says so.**
///
/// Two earlier versions were both wrong, in opposite directions. `Task.sleep` was cancellable, so it
/// proved the easy case and stayed silent on the one that mattered. A fixed three-second
/// `DispatchQueue` timer fixed that and introduced a **~50% flake**: the deadline is an unstructured
/// `Task` touching a `@MainActor` model, so it must hop to the main actor to run, and under ~1130
/// parallel tests that hop is sometimes delayed past three seconds — at which point the store wins
/// and an assertion about *causality* silently becomes one about *scheduling*.
///
/// **Releasing by hand removes the clock entirely.** Nothing can resume this call except the test,
/// so `didFinish == false` before `release()` is not merely likely — it is guaranteed by
/// construction, which is what the assertion was always trying to say.
///
/// `SubscriptionStore.loadOffer()` awaits `isEligibleForIntroOffer(for:)`, which is `async` and
/// **not throwing** and so cannot report cancellation at all. A continuation nobody resumes models
/// that exactly.
private actor HangingStore: SubscriptionPurchasing {
    /// Whether the hung call has finished. False until `release()`, deterministically.
    private(set) var didFinish = false

    /// How many times the store was actually asked — the only way to tell a retry that ran from one
    /// the model swallowed at its re-entry guard, since `phase` looks identical either way.
    private(set) var attempts = 0

    /// **An array, because more than one load can be in flight.** `aRetryAfterTheDeadlineIsAttempted`
    /// deliberately has two; a single slot would drop the first and hang the test forever.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func loadOffer() async throws -> SubscriptionOffer {
        attempts += 1
        await withCheckedContinuation { waiting.append($0) }
        didFinish = true
        throw SubscriptionStoreError.productsUnavailable
    }

    /// Let every hung call finish, once the test has asserted what it needs to.
    func release() {
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }

    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        .cancelled
    }

    func restore() async throws {}
}

/// Hangs the **first** call until released, then answers every later one.
///
/// The shape the generation guard exists for: an abandoned load still in flight while a newer one
/// completes. A store that only ever hangs cannot produce it, and one that always answers cannot
/// either.
private actor HangThenAnswerStore: SubscriptionPurchasing {
    private(set) var attempts = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func loadOffer() async throws -> SubscriptionOffer {
        attempts += 1
        if attempts == 1 {
            await withCheckedContinuation { waiting.append($0) }
            // The abandoned load reports no offer, which is what would overwrite a working paywall.
            throw SubscriptionStoreError.productsUnavailable
        }
        return .preview
    }

    func release() {
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }

    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        .cancelled
    }

    func restore() async throws {}
}

/// Answers `loadOffer` and refuses every purchase, so `.failed` is reachable in one call.
private actor FailingPurchaseStore: SubscriptionPurchasing {
    func loadOffer() async throws -> SubscriptionOffer { .preview }

    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        throw SubscriptionStoreError.storeKit("The App Store could not complete that.")
    }

    func restore() async throws {}
}

/// Hangs inside `purchase` until released, then throws — so a foreground can land in the gap.
private actor HangingPurchaseStore: SubscriptionPurchasing {
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    func loadOffer() async throws -> SubscriptionOffer { .preview }

    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        if !released {
            await withCheckedContinuation { waiting = $0 }
        }
        throw SubscriptionStoreError.storeKit("The App Store could not complete that.")
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }

    func restore() async throws {}
}

/// A one-way switch, so the household read can change its answer mid-test.
private actor GrantFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// Counts calls, so a double can fail the first and answer the rest.
private actor FailureCount {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// A store that answers immediately, to prove the timeout does not pre-empt a working one.
private actor InstantStore: SubscriptionPurchasing {
    func loadOffer() async throws -> SubscriptionOffer { .preview }
    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        .purchased
    }
    func restore() async throws {}
}
