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

    @Test("the trial welcome is owed once and then never again")
    func trialWelcomeIsOwedOnce() {
        var record = MembershipPresentationRecord()
        #expect(MembershipPresentation.shouldShowTrialWelcome(record: record))
        record.trialWelcomeShown = true
        #expect(MembershipPresentation.shouldShowTrialWelcome(record: record) == false)
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

    // MARK: - The end of the board

    /// *"Nothing waiting. Today's prompts arrive in the morning"* under four locked cards is a flat
    /// contradiction on one screen: the prompts **have** arrived.
    @Test("a locked board with nothing done gets no end-of-board card")
    func lockedBoardSuppressesNothingYet() {
        #expect(AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 0, doneToday: 0, locked: 0) == .nothingYet)
        #expect(AllCaughtUpCard.Mode.forBoard(today: 0, waiting: 0, doneToday: 0, locked: 3) == nil)
    }

    /// **And the other half, which is the one worth defending.** A free parent who answered today's
    /// question has finished everything they were offered, and withholding the acknowledgement
    /// because they did not pay would be the meanest available reading.
    @Test("all caught up survives a locked board when something was actually done")
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
        var strings: [String] = [
            MembershipCopy.lockedFooter,
            MembershipCopy.title, MembershipCopy.subtitle,
            MembershipCopy.addsLabel, MembershipCopy.freeLabel,
            MembershipCopy.primaryAction, MembershipCopy.notNow, MembershipCopy.notNowHint,
            MembershipCopy.footnote, MembershipCopy.productsUnavailable,
            MembershipCopy.TrialWelcome.title, MembershipCopy.TrialWelcome.body,
            MembershipCopy.TrialWelcome.action,
            MembershipCopy.postTrialNotice, MembershipCopy.postTrialOpen,
            MembershipCopy.postTrialDismiss,
        ]
        strings += MembershipCopy.adds
        strings += MembershipCopy.stayFree

        let slots: [Slot] = [.mission, .missionB, .weekly, .monthly, .letter, .unknown("seasonal")]
        for slot in slots {
            strings.append(MembershipCopy.lockedEyebrow(slot))
            strings.append(MembershipCopy.lockedBody(slot))
        }

        for string in strings {
            let lowered = string.lowercased()
            for banned in ["unlock", "upgrade", "premium", "don't lose", "you've missed",
                           "limited time", "members only", "free trial ending"] {
                #expect(
                    !lowered.contains(banned),
                    "\"\(string)\" contains the banned phrase \"\(banned)\""
                )
            }
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
