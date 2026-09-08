import Foundation
import Testing

@testable import Rascal

/// **Phase 147 — a household that is not entitled may not add new media.**
///
/// The owner's call of Sep 6, 2026, which reverses part of D2: photo, video and audio come off the
/// free tier entirely, and writing and did-it stay free and unlimited. This suite pins the client
/// half — that the app never *offers* an action the server will refuse, and that it offers a way to
/// join instead.
///
/// **Everything here is a pure type or a model.** `RascalTests` has no view host, so nothing inside
/// a `body` is reachable — which is exactly why `AddToArchiveModel`, `AddToArchiveVerb` and
/// `MembershipPresentation.mayAddMedia` exist as types rather than as conditions in
/// `AddToArchiveSheet` and `RootView`. A rule that lives in a view is a rule this file could not
/// have caught.
@Suite("Phase 147 — media is membership")
struct MediaMembershipTests {

    // MARK: - The gate, and which households it opens for

    /// A `FamilySummary` off the wire, so every case below decodes the document the server actually
    /// sends rather than a memberwise value a test author chose.
    private func household(_ json: String) throws -> FamilySummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FamilySummary.self, from: Data(json.utf8))
    }

    /// **The five answers the API lane's gate gives, pinned one for one.**
    ///
    /// The server refuses `POST /media/upload-url` with `402 subscription_required` only when
    /// `Access.entitled` is false — `entitled = subscribed or granted or in_trial` — so free is the
    /// only household refused and the client must refuse exactly that set and no more.
    ///
    /// **The trial is the case this phase had to get right.** The brief first named
    /// `FamilySummary.isMember`, which is `receipt || grant` and excludes a trial; the coordinator
    /// corrected it on Sep 6, 2026 once the server gate shipped on `entitled`. A household inside
    /// its fourteen days may add media, which is what *"Two weeks, everything open"* promised it.
    @Test("free is gated; subscribed, granted and trial are not")
    func theGateMatchesTheServer() throws {
        let free = try household("""
            {"family_id":"00000000-0000-0000-0000-000000000001","tier":"free","access":"free",
             "entitled":false,"entitlement_source":"none","guardians":[],"pending_invites":[]}
            """)
        let subscribed = try household("""
            {"family_id":"00000000-0000-0000-0000-000000000002","tier":"subscribed",
             "access":"subscribed","entitled":true,"entitlement_source":"receipt",
             "guardians":[],"pending_invites":[]}
            """)
        let granted = try household("""
            {"family_id":"00000000-0000-0000-0000-000000000003","tier":"free",
             "access":"subscribed","entitled":true,"entitlement_source":"grant",
             "guardians":[],"pending_invites":[]}
            """)
        let trial = try household("""
            {"family_id":"00000000-0000-0000-0000-000000000004","tier":"free","access":"trial",
             "entitled":true,"entitlement_source":"trial","guardians":[],"pending_invites":[]}
            """)

        #expect(MembershipPresentation.mayAddMedia(household: free) == false)
        #expect(MembershipPresentation.mayAddMedia(household: subscribed))
        #expect(MembershipPresentation.mayAddMedia(household: granted))
        #expect(MembershipPresentation.mayAddMedia(household: trial))

        // And the predicate this is deliberately **not**: `isMember` would refuse the trial.
        #expect(trial.isMember == false, "the paywall exists to be shown to a trial")
        #expect(granted.isMember, "a grant is on the paying side of that line")
    }

    /// **Not knowing means entitled, and there are two ways not to know.**
    ///
    /// `entitled` is `Bool?` because a server predating phase 121 sends no key at all, and
    /// `household` is nil until `GET /v1/families/me` has answered this session — a parent in a
    /// tunnel, a launch whose first read failed. D9 settles both: the device never decides
    /// entitlement, and a value it cannot read means entitled. The server's 402 is the backstop, and
    /// phase 147 makes that a calm sentence with a way in rather than an error.
    ///
    /// **Inverting this compiles and passes every test written against known values**, and refuses a
    /// photograph to somebody who has paid.
    @Test("a nil entitled and an unread household both fail open")
    func notKnowingFailsOpen() throws {
        let older = try household("""
            {"family_id":"00000000-0000-0000-0000-000000000005","tier":"free",
             "guardians":[],"pending_invites":[]}
            """)
        #expect(older.entitled == nil, "a server that predates the field sends no key")
        #expect(MembershipPresentation.mayAddMedia(household: older))
        #expect(MembershipPresentation.mayAddMedia(household: nil), "not read yet is not a paywall")
    }

    /// **The two server answers cannot disagree, and this is why the board may keep reading
    /// `access` while the gate reads `entitled`.**
    ///
    /// `services/guardians.access_for` computes
    /// `entitled = subscribed or granted or in_trial` and then
    /// `access = "subscribed" if (subscribed or granted) else ("trial" if entitled else "free")`,
    /// so `access != "free"` and `entitled` are the same boolean by construction — the only way to
    /// read `free` is `not entitled`. `TodayBoard.lockedSlots(in:)` gates the locked cards on
    /// `Access.isEntitled` and `RootView` gates the media verbs on `entitled`; this pins that the
    /// two cannot show a parent a locked board beside a live camera button, or the reverse.
    ///
    /// A server that ever broke the invariant would fail here rather than in front of a parent.
    @Test("access and entitled are the same boolean on every document the server can send")
    func theTwoServerAnswersCannotDisagree() throws {
        let documents = [
            ("free", false), ("trial", true), ("subscribed", true),
        ]
        for (access, entitled) in documents {
            let summary = try household("""
                {"family_id":"00000000-0000-0000-0000-000000000006","tier":"free",
                 "access":"\(access)","entitled":\(entitled),
                 "guardians":[],"pending_invites":[]}
                """)
            let boardSaysEntitled = summary.access?.isEntitled ?? true
            #expect(
                boardSaysEntitled == MembershipPresentation.mayAddMedia(household: summary),
                "the board and the gate disagree on access: \(access)"
            )
        }
    }

    // MARK: - What the + sheet offers

    /// **Write survives, and it is the only verb that does.** Did-it never was a verb on this sheet
    /// — it is a completion mode reached from a mission card — so what this pins is the free
    /// household's half of the bargain as this surface can express it.
    @Test("a household that may not add media is offered writing, and nothing that adds a file")
    func theFreeSheetOffersWritingAlone() {
        let sheet = AddToArchiveModel(authorization: .authorized, mayAddMedia: false)

        #expect(sheet.verbs == [.write])
        #expect(sheet.verbs.contains(.photo) == false)
        #expect(sheet.verbs.contains(.camera) == false)
        #expect(sheet.verbs.contains(.voice) == false)
        // Hoisted: `allSatisfy` is `rethrows`, which `#expect` will not compile inside itself.
        let nothingOffered_addsAFile = sheet.verbs.allSatisfy { !$0.addsMedia }
        #expect(nothingOffered_addsAFile)
        #expect(sheet.includesCameraRoll == false, "browsing the roll files photographs")
    }

    /// The call to action, in the slot the camera roll had. Never both, and never neither.
    @Test("the free sheet carries a way to join, and the full sheet does not")
    func theFreeSheetCarriesTheCallToAction() {
        let free = AddToArchiveModel(authorization: .authorized, mayAddMedia: false)
        let member = AddToArchiveModel(authorization: .authorized, mayAddMedia: true)

        #expect(free.includesMembership)
        #expect(free.includesCameraRoll == false)
        #expect(member.includesMembership == false)
        #expect(member.includesCameraRoll)
        #expect(
            free.includesMembership != free.includesCameraRoll,
            "exactly one row stands below the divider"
        )
    }

    /// **A member's sheet is byte-for-byte what it was**, which is the half of this phase that is
    /// easiest to break and hardest to notice.
    @Test("a household that may add media sees the sheet unchanged")
    func theMemberSheetIsUnchanged() {
        let sheet = AddToArchiveModel(authorization: .authorized, mayAddMedia: true)

        #expect(sheet.verbs == [.photo, .camera, .voice, .write])
        #expect(sheet.includesCameraRoll)
        #expect(sheet.includesMembership == false)
        #expect(sheet.cameraRollTitle == "Browse your camera roll")
    }

    /// **The default is entitled**, and it is the default because every construction site that does
    /// not know is a site that must offer everything. `RootView` is the only caller that passes a
    /// value.
    @Test("a model built without an answer offers everything")
    func theDefaultIsGenerous() {
        #expect(AddToArchiveModel().mayAddMedia)
        #expect(AddToArchiveModel().verbs.count == 4)
        #expect(AddToArchiveModel().includesCameraRoll)
    }

    /// **The two dimensions are independent, and the camera-roll row's own rule survives.**
    ///
    /// The row is present in every authorization state — the sealed-door defect this model was
    /// written for — and absent in exactly one entitlement state. Folding them into one flag is how
    /// the first bug comes back.
    @Test("authorization never gates the camera-roll row; entitlement is the only thing that does")
    func theTwoDimensionsStayIndependent() {
        for authorization in [
            BackfillAuthorization.authorized, .limited, .denied, .notDetermined,
        ] {
            #expect(
                AddToArchiveModel(authorization: authorization, mayAddMedia: true)
                    .includesCameraRoll,
                "row missing for an entitled household at \(authorization)"
            )
            #expect(
                AddToArchiveModel(authorization: authorization, mayAddMedia: false)
                    .includesCameraRoll == false,
                "row offered to a household that cannot use it at \(authorization)"
            )
        }
    }

    /// The verb table, pinned because three of its four rows are what this phase removes and the
    /// fourth is what it protects.
    @Test("write is the one verb that adds no file, and its opening is the writing one")
    func theVerbTableIsExact() {
        #expect(AddToArchiveVerb.photo.addsMedia)
        #expect(AddToArchiveVerb.camera.addsMedia)
        #expect(AddToArchiveVerb.voice.addsMedia)
        #expect(AddToArchiveVerb.write.addsMedia == false)

        #expect(AddToArchiveVerb.write.opening == .writing)
        #expect(AddToArchiveVerb.photo.opening == .library)
        #expect(AddToArchiveVerb.camera.opening == .camera)
        #expect(AddToArchiveVerb.voice.opening == .recorder)

        #expect(AddToArchiveVerb.allCases.count == 4)
    }

    // MARK: - The copy

    /// **Every string this surface can put in front of a parent comes from `MembershipCopy`**, and
    /// the one new sentence is in the guard list so the banned-phrase sweep in `MembershipTests`
    /// covers it like every other. A string that escaped that list would be copy nobody checks.
    @Test("the sheet's membership strings are the approved ones, and the new one is guarded")
    func theSheetSaysWhatTheCopyFileSays() {
        let free = AddToArchiveModel(mayAddMedia: false)

        #expect(free.membershipTitle == MembershipCopy.primaryAction)
        #expect(free.membershipTitle == "Become a member", "copy-file rule 2: a person joins")
        #expect(free.membershipSubtitle == MembershipCopy.mediaIncluded)
        #expect(
            MembershipCopy.allUserVisibleStrings.contains(MembershipCopy.mediaIncluded),
            "the new sentence escaped the banned-phrase guard"
        )
    }

    /// The tone rules, run against the one sentence this phase authored. Redundant with
    /// `MembershipTests`' sweep by design — the sweep proves the list is clean, and this proves the
    /// specific sentence is in it and says nothing this product does not say.
    @Test("the authored sentence carries no ban, no count and no urgency")
    func theAuthoredSentenceIsInTone() {
        let sentence = MembershipCopy.mediaIncluded

        for banned in MembershipCopy.bannedPhrases {
            #expect(
                !MembershipCopy.contains(banned, in: sentence),
                "\"\(sentence)\" contains the banned phrase \"\(banned)\""
            )
        }
        let carriesADigit = sentence.contains(where: \.isNumber)
        #expect(!carriesADigit, "nothing on this surface counts anything")
        // Rule 4: the lock states inclusion, not deprivation.
        #expect(sentence.contains("included with membership"))
        for scold in ["missed", "lose", "left", "expire", "run out", "only"] {
            #expect(
                sentence.lowercased().contains(scold) == false,
                "urgency or guilt in \"\(sentence)\": \(scold)"
            )
        }
    }

    // MARK: - The server's refusal, when this device's picture was stale

    /// **The refusal and the post-trial note are coalesced, never stacked.** Two membership
    /// notices on one board read as two paywalls; `SubscriptionSection` coalesces its three
    /// channels for the same reason.
    @Test("the refusal outranks the post-trial note, and neither is invented")
    func theBoardShowsOneMembershipNotice() {
        #expect(
            MembershipPresentation.boardMembershipNotice(refusal: nil, postTrial: nil) == nil
        )
        #expect(
            MembershipPresentation.boardMembershipNotice(
                refusal: nil, postTrial: MembershipCopy.postTrialNotice
            ) == MembershipCopy.postTrialNotice
        )
        #expect(
            MembershipPresentation.boardMembershipNotice(
                refusal: MembershipCopy.mediaIncluded, postTrial: nil
            ) == MembershipCopy.mediaIncluded
        )
        #expect(
            MembershipPresentation.boardMembershipNotice(
                refusal: MembershipCopy.mediaIncluded, postTrial: MembershipCopy.postTrialNotice
            ) == MembershipCopy.mediaIncluded,
            "the file the parent added seconds ago outranks the fortnight that ended"
        )
    }
}

/// The model half of the same phase, driven against a scripted server.
///
/// Separate suite because these are `@MainActor` and build a real `TodayModel` — the same harness
/// `MembershipTests` uses for the post-trial notice, and for the same reason: the rule under test
/// is one the model applies to a response, not one a pure helper can be asked in isolation.
@MainActor
@Suite("Phase 147 — the board's own answer")
struct MediaMembershipBoardTests {

    private func model(access: String?, status: Int = 200) -> TodayModel {
        let performer = StubPerformer()
        let child = UUID()
        let accessKey = access.map { "\"access\": \"\($0)\"," } ?? ""
        let json = """
            { "date": "2026-09-06", \(accessKey)
              "child": { "id": "\(child.uuidString)", "name": "Milo", "age_months": 50 },
              "today": [], "waiting": [], "done_today": [], "locked": [] }
            """
        performer.on("/today") { _ in (Data(json.utf8), status) }
        return TodayModel(
            childId: child,
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            presentation: InMemoryMembershipPresentationStore()
        )
    }

    /// **The board's own answer, read from the board's own response.**
    ///
    /// This is what `TodayBoard.lockedSlots(in:)` gates the locked cards on. It is **not** the media
    /// gate — that is `GET /families/me`'s `entitled`, asserted in the suite above — and the two are
    /// the same boolean by construction, which `theTwoServerAnswersCannotDisagree` pins. Both are
    /// kept under test because they arrive on two different documents and nothing but that invariant
    /// stops them drifting.
    @Test("the board reports the access the server sent, and nothing it worked out itself")
    func theBoardReportsWhatTheServerSent() async {
        let free = model(access: "free")
        await free.load()
        #expect(free.reportedAccess == .free)
        #expect(free.reportedAccess?.isEntitled == false)

        let trial = model(access: "trial")
        await trial.load()
        #expect(trial.reportedAccess == .trial)
        #expect(trial.reportedAccess?.isEntitled == true, "everything open means everything open")

        let subscribed = model(access: "subscribed")
        await subscribed.load()
        #expect(subscribed.reportedAccess?.isEntitled == true)
    }

    /// **A board that never landed reports nothing**, and a board that has not been asked yet does
    /// too — neither is `free`. The failure direction is the load-bearing part of this phase, and it
    /// is the same on both documents.
    @Test("a failed load and an unloaded board report no access at all")
    func aBoardThatDidNotLandReportsNothing() async {
        let unloaded = model(access: "free")
        #expect(unloaded.reportedAccess == nil, "nothing has been read")

        let failed = model(access: "free", status: 500)
        await failed.load()
        #expect(failed.reportedAccess == nil, "a request that failed saw nothing")
    }

    /// A server that predates phase 107 sends no `access` at all. Every build must render exactly
    /// as it did before that phase existed — no locked cards, no empty state, no crash.
    @Test("a server that reports no access reads as entitled, not as free")
    func anOlderServerIsGenerous() async {
        let older = model(access: nil)
        await older.load()
        #expect(older.reportedAccess == .notReported)
        #expect(older.reportedAccess?.isEntitled == true)
    }

    /// **The refusal note goes the moment the household is entitled**, for the reason the
    /// post-trial one does: its own action opens the sheet, so a parent can join without the board
    /// reloading underneath them, and a sentence saying photographs are membership must not still be
    /// standing over a board that just unlocked.
    @Test("becoming entitled clears the refusal note")
    func entitlementClearsTheRefusal() async {
        let free = model(access: "free")
        await free.load()
        free.noteMediaRefusal()
        #expect(free.standingMembershipNotice == MembershipCopy.mediaIncluded)

        // The same model, told by the server that the household is now subscribed.
        let subscribed = model(access: "subscribed")
        subscribed.noteMediaRefusal()
        await subscribed.load()
        #expect(subscribed.standingMembershipNotice == nil)
        #expect(subscribed.reportedAccess?.isEntitled == true)
    }

    /// **Dismiss takes off the one that is showing.** Clearing both would silently spend a note the
    /// parent never read — and the post-trial note is a once-ever presentation, so spending it is
    /// permanent.
    @Test("dismiss clears the standing notice and leaves the other one owed")
    func dismissClearsOnlyWhatIsShowing() async {
        let model = model(access: "free")
        await model.load()
        model.noteMediaRefusal()
        #expect(model.standingMembershipNotice == MembershipCopy.mediaIncluded)

        model.dismissMembershipNotice()
        #expect(model.standingMembershipNotice == nil, "the refusal went")

        // And with nothing standing, a second dismiss is harmless rather than destructive.
        model.dismissMembershipNotice()
        #expect(model.standingMembershipNotice == nil)
    }
}
