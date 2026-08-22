import Foundation
import Testing

@testable import Rascal

/// Phase 112 — the Settings membership row, and the contrast fix that came with it.
///
/// **The defect this suite exists for is one line old and three phases wide.** `SubscriptionSection`
/// reported the household by asking `tier`, which is constrained to `free | subscribed` and has no
/// word for a trial — so from phase 37a until now a household three days into its two weeks read
/// **"Free"** in Settings, while `GET /families/me` had been carrying `access` since phase 107 and
/// `FamilySummary`'s own doc comment said in terms that anything needing to tell those apart has to
/// read it.
///
/// The 29 tests in `MembershipTests` are phase 108's and are untouched.
@Suite("Phase 112 — the Settings membership row")
struct SettingsMembershipTests {

    // MARK: - Fixtures

    /// A `/families/me` body good enough for `FamilySummary`.
    ///
    /// `access` is genuinely **omitted** when nil rather than sent as JSON `null`, because those are
    /// different wires and only the omission is what a pre-107 server produces.
    private static func familyJSON(
        tier: String,
        access: String? = nil,
        extraFields: String = ""
    ) -> String {
        let accessField = access.map { "\"access\": \"\($0)\"," } ?? ""
        return """
            {
              "family_id": "33333333-3333-3333-3333-333333333333",
              "tier": "\(tier)",
              \(accessField)
              \(extraFields)
              "guardians": [],
              "pending_invites": []
            }
            """
    }

    private func family(_ json: String) throws -> FamilySummary {
        try APIClient.decoder.decode(FamilySummary.self, from: Data(json.utf8))
    }

    private func status(tier: String, access: String?) throws -> String {
        let household = try family(Self.familyJSON(tier: tier, access: access))
        return MembershipPresentation.settingsStatus(for: household)
    }

    /// `ios/Rascal/Rascal`, resolved from this file rather than from a working directory, so the
    /// source scans below survive being run from Xcode, from `xcodebuild`, and from CI.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rascal")
    }

    // MARK: - The defect

    /// **The headline. This is the assertion the phase is for.**
    ///
    /// Written as two expectations rather than one because the second is the regression: it is not
    /// enough that the trial now says something, it must specifically stop saying **"Free"**, which
    /// is the exact false sentence a paying-in-two-weeks household read for three phases.
    @Test("a household inside its trial no longer reads Free")
    func trialNoLongerReadsFree() throws {
        let value = try status(tier: "free", access: "trial")

        #expect(value == MembershipCopy.Status.everythingOpen)
        #expect(
            value != MembershipCopy.Status.free,
            "the row is asking `tier` again — a trial household is `tier: free` and must not say so"
        )
    }

    @Test("a subscribed household reads Subscribed")
    func subscribedReadsSubscribed() throws {
        let value = try status(tier: "subscribed", access: "subscribed")
        #expect(value == MembershipCopy.Status.subscribed)
    }

    @Test("a genuinely free household still reads Free")
    func freeReadsFree() throws {
        let value = try status(tier: "free", access: "free")
        #expect(value == MembershipCopy.Status.free)
    }

    // MARK: - The two ways of not knowing, which are not the same way

    /// **No household yet is not the same answer as `free`.** The row has never been allowed to say
    /// "Free" on the strength of never having looked, and this phase does not start.
    @Test("no household yet claims nothing")
    func noHouseholdClaimsNothing() {
        #expect(MembershipPresentation.settingsStatus(for: nil) == MembershipCopy.Status.unknown)
    }

    /// **A server predating phase 107 sends no `access` at all**, and on such a server `tier` is the
    /// whole truth rather than a lossy half of it — it has no trial to be wrong about. So the
    /// fallback is not the old defect returning; it is the only correct answer available, and it
    /// keeps every pre-107 build rendering exactly as it did.
    ///
    /// The payload really omits the key. A test that sent `"access": null` would prove something
    /// else.
    @Test("an absent access falls back to tier, which is the whole truth on a server that old")
    func absentAccessFallsBackToTier() throws {
        let json = Self.familyJSON(tier: "subscribed", access: nil)
        #expect(!json.contains("access"), "the fixture stopped omitting the field it exists to omit")

        let subscribed = try status(tier: "subscribed", access: nil)
        let free = try status(tier: "free", access: nil)
        #expect(subscribed == MembershipCopy.Status.subscribed)
        #expect(free == MembershipCopy.Status.free)
    }

    /// **A word this build does not know says nothing rather than guessing.**
    ///
    /// Both halves matter and they pull in opposite directions, which is why they are asserted
    /// together: under **D9** an unrecognised `access` still means *entitled*, so the board must
    /// stay open — and at the same time "entitled" is not the claim "Subscribed", so the row must
    /// not name a membership it cannot read. Naming the wrong one is worse than naming none.
    @Test("an access value this build cannot read claims no membership but still entitles")
    func unrecognisedAccessClaimsNothingAndStillEntitles() throws {
        let household = try family(Self.familyJSON(tier: "free", access: "founding_member"))

        #expect(MembershipPresentation.settingsStatus(for: household) == MembershipCopy.Status.unknown)
        #expect(
            household.access?.isEntitled == true,
            "D9 inverted — an unknown access must open the board, never paywall it"
        )
    }

    // MARK: - Old clients, new servers

    /// **Phase 113's four new fields arriving at a build that predates them.**
    ///
    /// Lane A is adding `lapsed_at`, `plan`, `billing_retry` and `is_payer` to `FamilyOut` while
    /// this build is in the field. `FamilySummary` declares none of them, and `Decodable` ignores
    /// unknown keys — but "it should be fine" is exactly the assumption worth pinning, because the
    /// cost of being wrong is every existing install failing to decode its own household the day
    /// the server deploys.
    ///
    /// The values are chosen to be the *awkward* ones: a non-null `lapsed_at`, an `is_payer` of
    /// `false`, and a `plan` this build has never heard of.
    @Test("the fields phase 113 adds decode away silently and change nothing here")
    func futureFieldsDecodeAndChangeNothing() throws {
        let extra = """
              "lapsed_at": "2026-08-01T12:00:00Z",
              "plan": "annual",
              "billing_retry": true,
              "is_payer": false,
            """
        let household = try family(
            Self.familyJSON(tier: "subscribed", access: "subscribed", extraFields: extra)
        )

        #expect(MembershipPresentation.settingsStatus(for: household) == MembershipCopy.Status.subscribed)
        #expect(household.isSubscribed)
    }

    /// The mirror of the above, and the case the phase brief names explicitly: **a payload missing
    /// the newer fields must render the nearest expressible state, never a lock and never a claim.**
    @Test("a payload with every newer field absent still renders, and renders no claim")
    func absentNewerFieldsStillRender() throws {
        let household = try family(Self.familyJSON(tier: "free", access: nil))

        #expect(household.access == nil)
        #expect(MembershipPresentation.settingsStatus(for: household) == MembershipCopy.Status.free)
    }

    // MARK: - The rules the row is not allowed to break

    /// **No countdown, no day counter, no date.** Rule 1 of the copy file bans counting outright,
    /// and the cheapest way for it to come back is somebody rendering `trial_ends_at` into this row
    /// as "9 days left". A digit in any of the four answers is the tell.
    @Test("no status answer contains a number")
    func noStatusAnswerCounts() {
        for value in [
            MembershipCopy.Status.subscribed,
            MembershipCopy.Status.everythingOpen,
            MembershipCopy.Status.free,
            MembershipCopy.Status.unknown,
        ] {
            // Hoisted out of the macro: `contains(where:)` is `rethrows`, and `#expect` cannot
            // resolve that to non-throwing on its own.
            let carriesADigit = value.contains(where: \.isNumber)
            #expect(
                !carriesADigit,
                "\"\(value)\" carries a digit, which is the countdown rule 1 forbids"
            )
        }
    }

    /// **Nothing on this surface does date arithmetic**, which is the standing rule that the device
    /// never decides entitlement. `trial_ends_at` is decoded elsewhere and deliberately read by
    /// nothing; the status row must not become its first reader.
    ///
    /// A source scan, in the idiom this suite already uses: it sees code no test path executes.
    @Test("the membership row does no date arithmetic and never reads the trial's end")
    func theRowDoesNoArithmetic() throws {
        // **`lapsedAt` is deliberately not here.** It was, briefly, and it fired on the
        // preview fixture that plumbs the field through — which is neither arithmetic nor a
        // read of the trial's end. Reading a lapse date is not the defect this guards.
        let banned = [
            "trialEndsAt", "trial_ends_at",
            "timeIntervalSince", "Date()", "Date.now", "dateComponents", "Calendar",
        ]

        for name in ["Subscription/SubscriptionSection.swift", "Subscription/MembershipPresentation.swift"] {
            let file = Self.sourceRoot.appendingPathComponent(name)
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.isEmpty, "\(name) moved and this test stopped looking")

            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Comments are where these are discussed, and this phase discusses them at length.
                if code.hasPrefix("//") || code.hasPrefix("///") || code.hasPrefix("*") { continue }

                for token in banned where code.contains(token) {
                    Issue.record("\(token) reached \(name):\(index + 1) — the device is deciding")
                }
            }
        }
    }

    // MARK: - The reassurance is the owner's, not an agent's

    /// **The copy file forbids an agent writing strings into a view**, so the block this phase puts
    /// on the card has to be the approved one, unchanged. Pinned by value rather than by reference
    /// so that editing `MembershipCopy` to say something friendlier fails here instead of shipping.
    @Test("the reassurance on the card is the owner's approved block, verbatim and in order")
    func theReassuranceIsTheApprovedBlock() {
        #expect(MembershipCopy.freeLabel == "What stays free, always")
        #expect(
            MembershipCopy.stayFree == [
                "A question every day, forever",
                "Everything you've already written or captured",
                "Search, and a full export of the whole archive",
            ]
        )
    }

    /// The four new strings go through the same banned-phrase guard as every other, rather than
    /// being trusted because they are short.
    @Test("no status answer contains a banned phrase")
    func noStatusAnswerIsBanned() {
        for value in [
            MembershipCopy.Status.subscribed,
            MembershipCopy.Status.everythingOpen,
            MembershipCopy.Status.free,
            MembershipCopy.Status.unknown,
        ] {
            #expect(MembershipCopy.allUserVisibleStrings.contains(value), "\"\(value)\" escaped the guard list")

            for banned in MembershipCopy.bannedPhrases where MembershipCopy.contains(banned, in: value) {
                Issue.record("banned phrase \"\(banned)\" in the status answer \"\(value)\"")
            }
        }
    }

    // MARK: - Contrast

    /// **`terracotta` `#C05A2B` on `surface` `#FFFDF9` is 4.36:1**, and every site this catches sets
    /// it at `.typeRole(.body)` — 16pt regular, which is *not* WCAG large text, so it needed 4.5:1
    /// and missed. `terracottaDeep` `#9A431E` is 6.47:1 on the same ground.
    ///
    /// **A source scan rather than a snapshot, because the defect is a token choice and it recurs by
    /// copy-paste.** Nine sites carried it when this phase started: `SettingsActionRow` — which is
    /// every action row in Settings — plus eight standalone labels the phase brief did not know
    /// about, found by sweeping the palette rather than by reading the component list.
    ///
    /// **Scoped to `Settings/` and `Subscription/` deliberately.** Six further sites survive in
    /// `Onboarding/`, `Timeline/` and `DesignSystemCatalog`, on `canvas` `#FDFAF4`, which is within a
    /// hair of `surface` and fails identically. They are outside this phase's surface and are
    /// reported rather than silently fixed — widening this scan is the follow-up phase's job.
    @Test("no body-size terracotta text survives in Settings or Subscription")
    func noBodySizeTerracottaInSettings() throws {
        let manager = FileManager.default
        var offenders: [String] = []

        for folder in ["Settings", "Subscription"] {
            let directory = Self.sourceRoot.appendingPathComponent(folder)
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            #expect(!files.isEmpty, "\(folder)/ moved and this test stopped looking")

            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)

                for (index, line) in lines.enumerated() where line.contains(".typeRole(.body)") {
                    // The modifier chain continues on the following lines.
                    //
                    // **A word boundary, not a suffix list.** The first version of this scan looked
                    // for `Color.terracotta)` and `Color.terracotta,` and therefore missed
                    // `isEnabled ? Color.terracotta : Color.inkMuted` — which is `SettingsActionRow`
                    // itself, the one site the whole finding is named after. It was caught by
                    // reintroducing the defect and watching this test stay green. `\b` matches
                    // `Color.terracotta` and not `Color.terracottaDeep`, whatever punctuation
                    // follows.
                    for offset in 1...2 where index + offset < lines.count {
                        let next = String(lines[index + offset])
                        // **Keyed on `foregroundStyle`, then on a bare `.terracotta`.** This is
                        // wider than the reachable defect on purpose. Two forms it now catches that
                        // `Color.terracotta` alone did not: `Color .terracotta` with a space, and
                        // the SwiftUI shorthand `.foregroundStyle(.terracotta)`. **The shorthand
                        // does not compile today** — these are `static let`s on `Color`, not
                        // `ShapeStyle` members, so the compiler rejects it — but it starts
                        // compiling the day somebody adds a `ShapeStyle` extension, and a guard
                        // that has to be widened at that moment is a guard nobody widens.
                        //
                        // Requiring `foregroundStyle` on the line is what keeps
                        // `ProgressView().tint(.terracotta)` out — a spinner is not text and is
                        // held to the 3:1 non-text bar, which `terracotta` clears at 4.36:1.
                        guard next.contains("foregroundStyle"),
                              next.firstMatch(of: /\.terracotta\b/) != nil
                        else { continue }
                        offenders.append("\(file.lastPathComponent):\(index + offset + 1)")
                    }
                }
            }
        }

        #expect(offenders.isEmpty, "16pt terracotta at 4.36:1 — below the 4.5:1 AA bar: \(offenders)")
    }
}

/// Phase 112 — tranche B: the four fields phase 113 added, and the one control they move.
///
/// **Only `is_payer` changes what renders.** `lapsed_at`, `plan` and `billing_retry` are decoded and
/// shown by nothing, because `free-tier-copy.md` has no string for the lapsed or grace states and
/// the file forbids an agent writing one. They are carried so the wire is not lost, and pinned here
/// so a later phase can render them without re-deriving the decode.
@Suite("Phase 112 tranche B — the membership wire")
struct MembershipWireTests {

    private static func familyJSON(
        tier: String,
        access: String,
        extraFields: String = ""
    ) -> String {
        """
        {
          "family_id": "44444444-4444-4444-4444-444444444444",
          "tier": "\(tier)",
          "access": "\(access)",
          \(extraFields)
          "guardians": [],
          "pending_invites": []
        }
        """
    }

    private func family(_ json: String) throws -> FamilySummary {
        try APIClient.decoder.decode(FamilySummary.self, from: Data(json.utf8))
    }

    // MARK: - The decode survives both directions

    /// **The case that is live right now**: this build, talking to production, which has not
    /// deployed 113 and sends none of these four keys.
    ///
    /// **`billing_retry` is the trap.** It is `bool` non-optional on the wire, and Swift's
    /// synthesized `Decodable` does **not** fall back to a property's default for a missing key — so
    /// a non-optional `Bool` here would fail the decode of the entire household and take the whole
    /// membership card down against every server now running. It is `Bool?` for that reason and read
    /// through `isInBillingRetry`.
    @Test("a server that has not deployed 113 still decodes, and reads as no grace and unknown payer")
    func aPre113ServerStillDecodes() throws {
        let household = try family(Self.familyJSON(tier: "subscribed", access: "subscribed"))

        #expect(household.lapsedAt == nil)
        #expect(household.plan == nil)
        #expect(household.billingRetry == nil)
        #expect(household.isInBillingRetry == false, "absent must collapse to not-in-grace")
        #expect(household.isPayer == nil)
        #expect(household.mayManageSubscription, "unknown payer must still offer Manage")
    }

    @Test("a 113 server's fields decode into the shapes the client expects")
    func aPost113ServerDecodes() throws {
        let household = try family(
            Self.familyJSON(
                tier: "subscribed",
                access: "subscribed",
                extraFields: """
                      "lapsed_at": null,
                      "plan": "annual",
                      "billing_retry": true,
                      "is_payer": true,
                    """
            )
        )

        #expect(household.plan == "annual")
        #expect(household.isInBillingRetry)
        #expect(household.isPayer == true)
    }

    /// **A `plan` value this build has never heard of must not throw.** It is a `String?` precisely
    /// so a third cadence invented server-side is data rather than a crash.
    @Test("an unrecognised plan decodes as itself rather than failing")
    func anUnrecognisedPlanDecodes() throws {
        let household = try family(
            Self.familyJSON(
                tier: "subscribed", access: "subscribed",
                extraFields: "\"plan\": \"quarterly\","
            )
        )
        #expect(household.plan == "quarterly")
    }

    // MARK: - is_payer, and the asymmetry that matters

    /// **The defect the phase brief names as one of the three likeliest**: `is_payer == nil` treated
    /// as `false`, which hides Apple's management sheet from a parent who is paying.
    @Test("an unknown payer still gets the Manage control")
    func unknownPayerKeepsManage() throws {
        let household = try family(
            Self.familyJSON(tier: "subscribed", access: "subscribed", extraFields: "\"is_payer\": null,")
        )
        #expect(MembershipPresentation.settingsAction(for: household) == .manage)
    }

    @Test("an explicit payer gets the Manage control")
    func explicitPayerGetsManage() throws {
        let household = try family(
            Self.familyJSON(tier: "subscribed", access: "subscribed", extraFields: "\"is_payer\": true,")
        )
        #expect(MembershipPresentation.settingsAction(for: household) == .manage)
    }

    /// **Only an explicit `false` hides it** — and it hides to *nothing*, never to the paywall.
    /// Offering "See the subscription" to a member because they are not the payer would try to sell
    /// a household a subscription it already has.
    @Test("a subscriber who is explicitly not the payer is offered nothing, and never the paywall")
    func explicitNonPayerIsOfferedNothing() throws {
        let household = try family(
            Self.familyJSON(tier: "subscribed", access: "subscribed", extraFields: "\"is_payer\": false,")
        )
        let action = MembershipPresentation.settingsAction(for: household)

        #expect(action == .hidden)
        #expect(action != .offer, "a member must never be sold what they already have")
    }

    /// **Manage is keyed on `tier`, not `access`.** A household inside its server-granted trial has
    /// no Apple subscription, so Apple's sheet would have nothing in it — they are offered the
    /// membership instead. This is the one place `tier` is still the right question.
    @Test("a trial household is offered the membership, not Apple's management sheet")
    func trialIsOfferedMembershipNotManage() throws {
        let household = try family(Self.familyJSON(tier: "free", access: "trial"))
        #expect(MembershipPresentation.settingsAction(for: household) == .offer)
    }

    @Test("no household yet is offered the membership, which is the shipped behaviour")
    func noHouseholdIsOfferedMembership() {
        #expect(MembershipPresentation.settingsAction(for: nil) == .offer)
    }

    // MARK: - The server-side invariant this client relies on

    /// Phase 113 guarantees `plan` and `billing_retry` are populated **only while subscribed**, so a
    /// household that lapsed from annual reports `plan: null`. This client encodes that as an
    /// assumption rather than checking it — this test records the assumption, so that if 113's
    /// invariant ever breaks the expectation is written down here rather than inferred from a render.
    @Test("a lapsed household carries a lapse date and no plan")
    func aLapsedHouseholdCarriesNoPlan() throws {
        let household = try family(
            Self.familyJSON(
                tier: "free", access: "free",
                extraFields: """
                      "lapsed_at": "2026-08-01T12:00:00Z",
                      "plan": null,
                      "billing_retry": false,
                    """
            )
        )

        #expect(household.lapsedAt != nil, "lapsed_at is what tells state 6 from state 5")
        #expect(household.plan == nil, "113's invariant: no plan on a household that is not subscribed")
        #expect(household.isInBillingRetry == false)
        // Nothing renders the lapse yet — there is no approved copy for it.
        #expect(MembershipPresentation.settingsStatus(for: household) == MembershipCopy.Status.free)
    }

    /// **A household in grace is fully entitled and reads as subscribed.** `billing_retry` moves no
    /// gate — that is the whole design, and asserting it here stops a later phase from quietly
    /// wiring it to one.
    @Test("billing retry moves no gate: a household in grace still reads Subscribed")
    func graceMovesNoGate() throws {
        let household = try family(
            Self.familyJSON(
                tier: "subscribed", access: "subscribed", extraFields: "\"billing_retry\": true,"
            )
        )

        #expect(household.isInBillingRetry)
        #expect(MembershipPresentation.settingsStatus(for: household) == MembershipCopy.Status.subscribed)
        #expect(MembershipPresentation.settingsAction(for: household) == .manage)
        #expect(household.access?.isEntitled == true)
    }
}
