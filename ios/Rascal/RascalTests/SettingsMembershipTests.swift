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

    /// The headline the card's header reports — `settingsStatus(for:)` until phase 144.
    private func status(tier: String, access: String?, extraFields: String = "") throws -> String {
        try header(tier: tier, access: access, extraFields: extraFields).headline
    }

    private func header(
        tier: String, access: String?, extraFields: String = ""
    ) throws -> MembershipPresentation.MembershipHeader {
        let household = try family(Self.familyJSON(tier: tier, access: access, extraFields: extraFields))
        return MembershipPresentation.settingsHeader(for: household)
    }

    /// The server's instant for every dated fixture here, parsed rather than built — the same
    /// rule the source scan below holds the surface to.
    private static let serverDate = ISO8601Formatters.parse("2026-09-17T00:00:00Z")!

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

        #expect(value == MembershipCopy.Card.trial)
        #expect(
            value != MembershipCopy.Card.free,
            "the row is asking `tier` again — a trial household is `tier: free` and must not say so"
        )
    }

    /// **The owner's ask, phase 144**: the count and the date, both the server's. The count
    /// renders only when the server sent one, the date only when it sent one, and neither is
    /// arithmetic here — the fixture's instant comes back through the formatter and nothing else.
    @Test("a trial's detail carries the server's day count and the server's date, and only those")
    func trialDetailIsTheServersCountAndDate() throws {
        let date = DayHeaderText.dayAndMonth(Self.serverDate)

        let both = try header(
            tier: "free", access: "trial",
            extraFields: "\"trial_ends_at\": \"2026-09-17T00:00:00Z\", \"trial_days_left\": 13,"
        )
        #expect(both.detail == "13 days left, until \(date). No card, nothing to cancel.")

        let lastDay = try header(
            tier: "free", access: "trial",
            extraFields: "\"trial_ends_at\": \"2026-09-17T00:00:00Z\", \"trial_days_left\": 1,"
        )
        #expect(lastDay.detail == "One day left, until \(date). No card, nothing to cancel.")

        // An older server sends the date and no count: no number, no "days left".
        let dateOnly = try header(
            tier: "free", access: "trial", extraFields: "\"trial_ends_at\": \"2026-09-17T00:00:00Z\","
        )
        #expect(dateOnly.detail == "Until \(date). No card, nothing to cancel.")
        #expect(dateOnly.detail?.contains("days left") == false)

        // A count with no date to sit beside is not rendered: a bare number is the countdown.
        let countOnly = try header(tier: "free", access: "trial", extraFields: "\"trial_days_left\": 13,")
        #expect(countOnly.detail == MembershipCopy.Card.trialDetailNoDate)
    }

    /// **The pin that stops a later phase keying the header on the date.** A trial that ended
    /// yesterday reads `access: free` from the server, and the header follows `access` — never
    /// "Free trial" over a date that has passed.
    @Test("a past trial end beside access free renders Free, never Free trial")
    func aPastTrialIsFree() throws {
        let value = try header(
            tier: "free", access: "free",
            extraFields: "\"trial_ends_at\": \"2026-08-01T00:00:00Z\", \"trial_days_left\": null,"
        )
        #expect(value.headline == MembershipCopy.Card.free)
        #expect(value.detail == MembershipCopy.Card.freeDetail)
    }

    /// **The headline is the plan, since phase 144** — the owner's call: *"Annual Membership
    /// please and if they are monthly it should say that."* No plan on the wire is the plain
    /// noun, never a guess at cadence and never the old "Subscribed".
    @Test("a subscribed household reads its plan, and the plain noun without one")
    func subscribedReadsThePlan() throws {
        #expect(try status(tier: "subscribed", access: "subscribed") == MembershipCopy.Card.membership)
        #expect(
            try status(tier: "subscribed", access: "subscribed", extraFields: "\"plan\": \"annual\",")
                == MembershipCopy.Card.annual
        )
        #expect(
            try status(tier: "subscribed", access: "subscribed", extraFields: "\"plan\": \"monthly\",")
                == MembershipCopy.Card.monthly
        )
        #expect(
            try status(tier: "subscribed", access: "subscribed", extraFields: "\"plan\": \"quarterly\",")
                == MembershipCopy.Card.membership,
            "a cadence this build has never heard of is a lookup miss, not a crash and not a guess"
        )
    }

    /// *Renews* / *Expires* / *Paid through*, by Apple's word — and no date line at all from a
    /// server that predates the field, which is production until the API half deploys.
    @Test("a subscribed household's detail is the period end, in Apple's word for it")
    func subscribedDetailIsThePeriodEnd() throws {
        let date = DayHeaderText.dayAndMonth(Self.serverDate)
        let period = "\"plan\": \"annual\", \"expires_at\": \"2026-09-17T00:00:00Z\","

        #expect(
            try header(tier: "subscribed", access: "subscribed", extraFields: period + "\"auto_renew\": true,").detail
                == "Renews \(date)"
        )
        #expect(
            try header(tier: "subscribed", access: "subscribed", extraFields: period + "\"auto_renew\": false,").detail
                == "Expires \(date)"
        )
        #expect(
            try header(tier: "subscribed", access: "subscribed", extraFields: period).detail
                == "Paid through \(date). Whether it renews is set in the App Store."
        )
        #expect(
            try header(tier: "subscribed", access: "subscribed", extraFields: "\"plan\": \"annual\",").detail
                == nil,
            "no period end on the wire is no date line, never an invented one"
        )
    }

    /// The explicit non-payer: the date when there is one, then who manages it, and never the
    /// pointer to an App Store this parent cannot reach.
    @Test("a subscriber who is not the payer is told who manages it")
    func notThePayerIsToldWhoManages() throws {
        let date = DayHeaderText.dayAndMonth(Self.serverDate)
        let paying = "\"plan\": \"annual\", \"is_payer\": false, \"expires_at\": \"2026-09-17T00:00:00Z\","

        #expect(
            try header(tier: "subscribed", access: "subscribed", extraFields: paying + "\"auto_renew\": true,").detail
                == "Renews \(date). Managed by the other parent."
        )
        #expect(
            try header(tier: "subscribed", access: "subscribed", extraFields: "\"is_payer\": false,").detail
                == MembershipCopy.Card.otherParent
        )
        // Never the retry sentence: it is an offer to fix, and this parent cannot fix it.
        #expect(
            try header(
                tier: "subscribed", access: "subscribed",
                extraFields: "\"is_payer\": false, \"billing_retry\": true,"
            ).detail == MembershipCopy.Card.otherParent
        )
    }

    /// The complimentary household: the header is the whole card, and a dated grant says what
    /// follows the date because there is no row beneath it to imply that nothing does.
    @Test("a granted household reads Complimentary membership, dated when the grant is")
    func grantedReadsComplimentary() throws {
        let date = DayHeaderText.dayAndMonth(Self.serverDate)
        let grant = "\"entitled\": true, \"entitlement_source\": \"grant\","

        let perpetual = try header(tier: "free", access: "subscribed", extraFields: grant)
        #expect(perpetual.headline == MembershipCopy.Card.complimentary)
        #expect(perpetual.detail == MembershipCopy.Card.complimentaryDetail)

        let dated = try header(
            tier: "free", access: "subscribed",
            extraFields: grant + "\"grant_expires_at\": \"2026-09-17T00:00:00Z\","
        )
        #expect(
            dated.detail
                == "Everything a member has, until \(date). After that the daily question keeps going, free."
        )
    }

    @Test("a genuinely free household still reads Free")
    func freeReadsFree() throws {
        let value = try header(tier: "free", access: "free")
        #expect(value.headline == MembershipCopy.Card.free)
        #expect(value.detail == MembershipCopy.Card.freeDetail)
    }

    // MARK: - The two ways of not knowing, which are not the same way

    /// **No household yet is not the same answer as `free`.** The row has never been allowed to say
    /// "Free" on the strength of never having looked, and this phase does not start.
    @Test("no household yet claims nothing, and says why")
    func noHouseholdClaimsNothing() {
        let header = MembershipPresentation.settingsHeader(for: nil)
        #expect(header.headline == MembershipCopy.Card.unknown)
        #expect(header.detail == MembershipCopy.Card.noAnswerYet)
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
        #expect(subscribed == MembershipCopy.Card.membership)
        #expect(free == MembershipCopy.Card.free)
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

        let header = MembershipPresentation.settingsHeader(for: household)
        #expect(header.headline == MembershipCopy.Card.unknown)
        #expect(header.detail == MembershipCopy.Card.unreadable, "a dash on its own is not a word")
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

        let header = MembershipPresentation.settingsHeader(for: household)
        #expect(header.headline == MembershipCopy.Card.annual)
        // An explicit non-payer in a retry is told who manages it, never the retry sentence.
        #expect(header.detail == MembershipCopy.Card.otherParent)
        #expect(household.isSubscribed)
    }

    /// The mirror of the above, and the case the phase brief names explicitly: **a payload missing
    /// the newer fields must render the nearest expressible state, never a lock and never a claim.**
    @Test("a payload with every newer field absent still renders, and renders no claim")
    func absentNewerFieldsStillRender() throws {
        let household = try family(Self.familyJSON(tier: "free", access: nil))

        #expect(household.access == nil)
        #expect(MembershipPresentation.settingsHeader(for: household).headline == MembershipCopy.Card.free)
    }

    // MARK: - The rules the row is not allowed to break

    /// **No authored constant carries a digit.** Rule 1 of the copy file bans counting, and phase
    /// 144 is the owner amending it for this one surface: a day count may render here **when the
    /// server sent one**. So the rule this test now holds is the one that survives the amendment —
    /// a number reaches this card only through `render`, from the wire, and never from a constant
    /// or a clock. The dated templates carry exactly one `{date}`; exactly one carries `{days}`.
    @Test("no authored constant contains a number, and the placeholders are where the wire lands")
    func noStatusAnswerCounts() {
        for value in MembershipCopy.Card.all {
            // Hoisted out of the macro: `contains(where:)` is `rethrows`, and `#expect` cannot
            // resolve that to non-throwing on its own.
            let carriesADigit = value.contains(where: \.isNumber)
            #expect(
                !carriesADigit,
                "\"\(value)\" carries a digit — a count must come from the wire, never from a constant"
            )
        }
        for template in MembershipCopy.Card.dated {
            let dates = template.components(separatedBy: MembershipCopy.Card.datePlaceholder).count - 1
            #expect(dates == 1, "\"\(template)\" should carry exactly one {date}")
        }
        let counting = MembershipCopy.Card.all.filter { $0.contains(MembershipCopy.Card.daysPlaceholder) }
        #expect(counting == [MembershipCopy.Card.trialDetail], "only the trial's detail counts")

        // And the render is the only door: the same template, the server's number in it.
        #expect(MembershipCopy.render(MembershipCopy.Card.trialDetail, date: "x", days: 9) == "9 days left, until x. No card, nothing to cancel.")
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
        // **`trialEndsAt` and `trial_ends_at` left this list with phase 144**, deliberately: the
        // surface now *reads* the trial's end to format it, and the amendment is recorded in
        // `free-tier-copy.md`. What stays banned is every way of computing from it. Fixture and
        // preview dates in the two scanned files are built with `ISO8601Formatters.parse(...)`,
        // which contains none of the kept tokens, so the constraint travels with the test.
        let banned = [
            "timeIntervalSince", "Date()", "Date.now", "dateComponents", "Calendar",
        ]

        for name in ["Subscription/SubscriptionSection.swift", "Subscription/MembershipPresentation.swift"] {
            let file = Self.sourceRoot.appendingPathComponent(name)
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.isEmpty, "\(name) moved and this test stopped looking")
            if name.hasSuffix("MembershipPresentation.swift") {
                #expect(
                    source.contains("DayHeaderText.dayAndMonth("),
                    "the surface may read and format a server date; the formatter is the one door"
                )
            }

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

    /// **The copy file forbids an agent writing strings into a view**, so the block has to be the
    /// approved one, unchanged. Pinned by value rather than by reference so that editing
    /// `MembershipCopy` to say something friendlier fails here instead of shipping. **Since phase
    /// 144 this pins the paywall's block, not the card's**: the owner had the block removed from
    /// the Settings card on Sep 3, 2026, and `PaywallSheet` still renders it.
    @Test("the reassurance is the owner's approved block, verbatim and in order")
    func theReassuranceIsTheApprovedBlock() {
        #expect(MembershipCopy.freeLabel == "Yours either way")
        #expect(
            MembershipCopy.stayFree == [
                "A new question every day, with no limit and no countdown.",
                "Everything you've already written and captured stays yours.",
                "Search the whole archive, and export all of it whenever you want.",
            ]
        )
    }

    /// Every card string goes through the same banned-phrase guard as every other, rather than
    /// being trusted because it was approved.
    @Test("no card string contains a banned phrase")
    func noStatusAnswerIsBanned() {
        for value in MembershipCopy.Card.all {
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
                let source = try String(contentsOf: file, encoding: .utf8)
                offenders += Self.bodySizeTerracotta(in: source, of: file.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty, "16pt terracotta at 4.36:1 — below the 4.5:1 AA bar: \(offenders)")
    }

    /// Every `foregroundStyle(…)` in *source* whose argument names bare `terracotta` and which sits
    /// beside a `.typeRole(.body)`.
    ///
    /// **This parses the call rather than matching a line, and that is the third shape of this
    /// guard.** The first matched `Color.terracotta)` and `Color.terracotta,` and missed the ternary
    /// `isEnabled ? Color.terracotta : Color.inkMuted` — which is `SettingsActionRow` itself, the one
    /// site the whole finding is named after. The second was keyed on a line containing both
    /// `foregroundStyle` and `.terracotta`, and missed the argument wrapped onto its own line, which
    /// is ordinary formatting for a long modifier. **Two consecutive widenings of a text match is
    /// the signal to stop widening the text match**, so this finds the call, walks its parentheses
    /// to the balancing one, and reads the argument it actually has.
    ///
    /// Comments are blanked first — this phase discusses `Color.terracotta` at length in prose.
    ///
    /// `\b` is what keeps `terracottaDeep` and `terracottaSoft` out, and requiring the enclosing
    /// call to be `foregroundStyle` is what keeps `ProgressView().tint(.terracotta)` out: a spinner
    /// is not text and is held to the 3:1 non-text bar, which `terracotta` clears at 4.36:1.
    static func bodySizeTerracotta(in source: String, of fileName: String) -> [String] {
        // Blank comment-only lines, preserving line numbering for the report.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let code = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
            return isComment ? String(repeating: " ", count: line.count) : String(line)
        }.joined(separator: "\n")

        let chars = Array(code)
        let needle = Array("foregroundStyle(")
        var offenders: [String] = []
        var i = 0

        while i + needle.count <= chars.count {
            guard Array(chars[i..<(i + needle.count)]) == needle else { i += 1; continue }

            // Walk to the balancing paren, so a nested call inside the argument is included.
            var depth = 0
            var j = i + needle.count - 1
            var closed = j
            while j < chars.count {
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" {
                    depth -= 1
                    if depth == 0 { closed = j; break }
                }
                j += 1
            }

            let argument = String(chars[(i + needle.count)..<max(closed, i + needle.count)])
            if argument.firstMatch(of: /\.terracotta\b/) != nil {
                // `.typeRole(.body)` may sit before or after the colour in the chain, so look both
                // ways over a window rather than assuming an order.
                let lower = max(0, i - 240)
                let upper = min(chars.count, closed + 240)
                let neighbourhood = String(chars[lower..<upper])
                if neighbourhood.contains(".typeRole(.body)") {
                    let line = code.prefix(i).filter { $0 == "\n" }.count + 1
                    offenders.append("\(fileName):\(line)")
                }
            }
            i = closed + 1
        }

        return offenders
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
    /// Offering "See what membership includes" to a member because they are not the payer would
    /// try to sell a household a subscription it already has.
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
        // Lapsed renders identically to never-subscribed, deliberately: the free tier is the same
        // tier either way, and the copy file declined to write a lapse sentence.
        #expect(MembershipPresentation.settingsHeader(for: household).headline == MembershipCopy.Card.free)
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
        let header = MembershipPresentation.settingsHeader(for: household)
        #expect(header.headline == MembershipCopy.Card.membership, "no plan on this fixture")
        #expect(header.detail == MembershipCopy.Card.billingRetry, "the fact and the reassurance")
        #expect(MembershipPresentation.settingsAction(for: household) == .manage)
        #expect(MembershipPresentation.manageDetail(for: household) == MembershipCopy.Card.manageDetailRetry)
        #expect(household.access?.isEntitled == true)
    }

    // MARK: - Phase 144: the five fields the card reads, and the rows they move

    /// The three phase 144 adds and the two it starts reading. All optional: a server that sends
    /// none of them — production, until the API half deploys — still decodes.
    @Test("the phase 144 fields decode when present and are nil when absent")
    func phase144FieldsDecode() throws {
        let absent = try family(Self.familyJSON(tier: "subscribed", access: "subscribed"))
        #expect(absent.trialEndsAt == nil)
        #expect(absent.trialDaysLeft == nil)
        #expect(absent.grantExpiresAt == nil)
        #expect(absent.expiresAt == nil)
        #expect(absent.autoRenew == nil)

        let present = try family(
            Self.familyJSON(
                tier: "subscribed", access: "subscribed",
                extraFields: """
                      "trial_ends_at": "2026-09-17T00:00:00Z",
                      "trial_days_left": 13,
                      "grant_expires_at": "2027-09-17T00:00:00Z",
                      "expires_at": "2027-09-17T00:00:00Z",
                      "auto_renew": false,
                    """
            )
        )
        #expect(present.trialEndsAt == ISO8601Formatters.parse("2026-09-17T00:00:00Z"))
        #expect(present.trialDaysLeft == 13)
        #expect(present.grantExpiresAt == ISO8601Formatters.parse("2027-09-17T00:00:00Z"))
        #expect(present.expiresAt == ISO8601Formatters.parse("2027-09-17T00:00:00Z"))
        #expect(present.autoRenew == false)
    }

    /// **Restore appears only where a restore could find something.** Hidden for every member
    /// state whatever the purchase phase says; disabled while a purchase is mid-flight; enabled
    /// again in `.late` and `.awaitingApproval`, where it is the one control that can nudge the
    /// server.
    @Test("the Restore row is offered to non-members, waits during a purchase, and hides for members")
    func restoreRowMatrix() throws {
        let trial = try family(Self.familyJSON(tier: "free", access: "trial"))
        let free = try family(Self.familyJSON(tier: "free", access: "free"))
        let lapsed = try family(
            Self.familyJSON(tier: "free", access: "free", extraFields: "\"lapsed_at\": \"2026-08-01T12:00:00Z\",")
        )
        let unread = try family(Self.familyJSON(tier: "free", access: "founding_member"))
        let payer = try family(Self.familyJSON(tier: "subscribed", access: "subscribed", extraFields: "\"is_payer\": true,"))
        let unknownPayer = try family(Self.familyJSON(tier: "subscribed", access: "subscribed"))
        let notPayer = try family(Self.familyJSON(tier: "subscribed", access: "subscribed", extraFields: "\"is_payer\": false,"))
        let retry = try family(Self.familyJSON(tier: "subscribed", access: "subscribed", extraFields: "\"billing_retry\": true,"))
        let granted = try family(
            Self.familyJSON(tier: "free", access: "subscribed", extraFields: "\"entitled\": true, \"entitlement_source\": \"grant\",")
        )

        for household in [trial, free, lapsed, unread] {
            #expect(MembershipPresentation.settingsRestore(for: household) == .offered)
            #expect(MembershipPresentation.settingsRestore(for: household, purchase: .purchasing) == .waiting)
            #expect(MembershipPresentation.settingsRestore(for: household, purchase: .confirming) == .waiting)
            #expect(MembershipPresentation.settingsRestore(for: household, purchase: .late) == .offered)
            #expect(MembershipPresentation.settingsRestore(for: household, purchase: .awaitingApproval) == .offered)
            #expect(MembershipPresentation.settingsRestore(for: household, purchase: .failed("no")) == .offered)
        }
        #expect(MembershipPresentation.settingsRestore(for: nil) == .offered, "no household yet: the row that can ask")
        #expect(MembershipPresentation.settingsRestore(for: nil, purchase: .confirming) == .waiting)

        for member in [payer, unknownPayer, notPayer, retry, granted] {
            for purchase in [SubscriptionModel.PurchasePhase.idle, .purchasing, .confirming, .late, .awaitingApproval] {
                #expect(
                    MembershipPresentation.settingsRestore(for: member, purchase: purchase) == .hidden,
                    "a member's restore can only confirm the header; \(purchase) must not bring it back"
                )
            }
        }
    }

    /// **The offer follows `isMember`, exactly as the sheet's buy button does** — never `access`.
    /// Every non-member `access` value, including one this build cannot read, is offered the
    /// membership; the trial is offered its own sentence.
    @Test("the offer row follows isMember across every access value, and the trial gets its own detail")
    func offerFollowsIsMember() throws {
        for access in ["trial", "free", "founding_member"] {
            let household = try family(Self.familyJSON(tier: "free", access: access))
            #expect(MembershipPresentation.settingsAction(for: household) == .offer, "access \(access)")
        }
        // The key genuinely omitted — a pre-107 server — rather than sent as null.
        let absent = try family("""
            {"family_id": "44444444-4444-4444-4444-444444444444", "tier": "free",
             "guardians": [], "pending_invites": []}
            """)
        #expect(MembershipPresentation.settingsAction(for: absent) == .offer)

        let trial = try family(Self.familyJSON(tier: "free", access: "trial"))
        #expect(MembershipPresentation.offerDetail(for: trial) == MembershipCopy.Card.offerDetailTrial)
        #expect(MembershipPresentation.offerDetail(for: absent) == MembershipCopy.Card.offerDetail)
        #expect(MembershipPresentation.offerDetail(for: nil) == MembershipCopy.Card.offerDetail)

        // A subscriber's `access` being unreadable changes nothing: Manage keys on `tier`.
        let paying = try family(Self.familyJSON(tier: "subscribed", access: "founding_member"))
        #expect(MembershipPresentation.settingsAction(for: paying) == .manage)
        #expect(MembershipPresentation.settingsHeader(for: paying).headline == MembershipCopy.Card.membership)
    }
}
