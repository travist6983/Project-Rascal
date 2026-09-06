import SwiftUI

/// What the **+** button asks for.
///
/// Deliberately a small enum rather than four closures: the sheet has to **dismiss before** any of
/// these can present, because presenting a sheet from a sheet that is on its way out drops the
/// second one. So the sheet records what was chosen, closes, and the root acts on it.
///
/// **`membership` rides the same mechanism for the same reason** (phase 147). The paywall is a
/// sheet too, so it cannot be presented from inside this one either — and routing it through here
/// means the call to action cannot accidentally become the one door that behaves differently.
enum AddToArchiveChoice: Equatable {
    case compose(ComposerOpening)
    case backfill
    case membership
}

/// One capture verb in the sheet's grid.
///
/// **A type rather than four calls in a `body`, because the set is now a decision.** Until phase
/// 147 the four were literals inside the view, which is a place no test can reach
/// (`RascalTests` has no view host). The set a household is offered is now a rule about
/// entitlement, and a rule that lives in a `body` is a rule that ships untested — the exact
/// failure `BackfillGrantChange` and `MembershipPresentation` exist to avoid.
nonisolated enum AddToArchiveVerb: String, CaseIterable, Equatable, Sendable, Identifiable {
    case photo
    case camera
    case voice
    case write

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: "Photo"
        case .camera: "Camera"
        case .voice: "Voice"
        case .write: "Write"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo.on.rectangle"
        case .camera: "camera"
        case .voice: "mic"
        case .write: "pencil"
        }
    }

    var opening: ComposerOpening {
        switch self {
        case .photo: .library
        case .camera: .camera
        case .voice: .recorder
        case .write: .writing
        }
    }

    /// **Whether taking this verb puts a new file in the archive.**
    ///
    /// Three of the four do. `write` does not, and that is the whole of the free tier's half of
    /// the owner's Sep 6, 2026 call: writing and did-it stay free and unlimited, and nothing about
    /// them changes on any tier.
    var addsMedia: Bool { self != .write }
}

/// What the **+** sheet shows, decided away from the view so all four authorization states — and,
/// since phase 147, both entitlement answers — can be asserted rather than looked at.
///
/// **The camera-roll row is unconditional in every authorization state, and that is the older half
/// of this type's job.** It used to be `if let offered` over the newest unlogged cluster, which
/// read as a tidy "no row when there is nothing to offer" — but clusters only exist once a scan
/// has run, a scan only runs with authorization, and the *only* place authorization is ever asked
/// for is the explainer behind this row. So on a phone that had never granted access the row was
/// absent, which meant the explainer was unreachable, which meant access was never granted, which
/// meant the row stayed absent. The feature was sealed behind its own door.
///
/// `docs/decisions.md` settles that **+** opens four capture verbs with the camera roll below a
/// divider as a fifth thing that is explicitly not a verb. That tap was paid on every entry; this
/// is the thing it bought.
///
/// ## Phase 147 — the second dimension, and it is orthogonal to the first
///
/// The owner's call of Sep 6, 2026: **a household that is not entitled may not add new media —
/// photo, video or audio. Writing and did-it stay free and unlimited.** So this type now answers
/// two independent questions, and the sealed-door bug above is the reason they are kept
/// independent rather than folded into one flag:
///
/// * **May this phone see the camera roll?** — `authorization`. Never gates the row, only its
///   subtitle.
/// * **May this household add media at all?** — `mayAddMedia`, which is the *server's* answer and
///   never this device's arithmetic.
///
/// When the second is false the three media verbs and the camera-roll row are **not offered at
/// all**, and a *Become a member* row stands where the camera roll was.
nonisolated struct AddToArchiveModel: Equatable, Sendable {
    /// What the scan last saw. `.notDetermined` before one has run, which is the honest default:
    /// nothing has been counted, so nothing is claimed.
    let authorization: BackfillAuthorization
    /// The newest unlogged month, when there is one. Never gates the row — only its subtitle.
    let offer: BackfillCluster?

    /// **The server's word, rendered and never recomputed** (iOS rule 1, D9).
    ///
    /// It is `GET /v1/families/me`'s `entitled`, passed in by `RootView` through
    /// `MembershipPresentation.mayAddMedia(household:)` — **the same field the API lane's gate keys
    /// on**, so this sheet offers exactly what the server will accept and never less.
    ///
    /// **`true` is the default, and that is the failure direction rather than a convenience.** A
    /// household not read yet, a read that failed, and a server older than phase 121 that sends no
    /// `entitled` at all arrive here as `true`: a parent in a tunnel is offered everything, a device
    /// never decides that a household has not paid, and the server's 402 is the backstop — which
    /// phase 147 makes a calm sentence with a way in rather than an error.
    ///
    /// **A household inside its fourteen days is entitled and is offered everything.** It is
    /// deliberately *not* `FamilySummary.isMember`, which is `receipt || grant` and excludes the
    /// trial — see `.claude/coordination/phase-147/CONTRACT_REQUEST-ios-1300.md`, which records why
    /// and carries the API lane's confirmation.
    let mayAddMedia: Bool

    init(
        authorization: BackfillAuthorization = .notDetermined,
        clusters: [BackfillCluster] = [],
        mayAddMedia: Bool = true
    ) {
        self.authorization = authorization
        self.offer = clusters.first
        self.mayAddMedia = mayAddMedia
    }

    /// The verbs to draw, in order.
    ///
    /// **The set shrinks; nothing is dimmed.** `docs/design-system.md` says so in five places and
    /// this is the same rule each time — `CaptureChoices`: *"an affordance that leads nowhere is
    /// worse than its absence"*, and the audio prompt that gets one Record tile rather than three
    /// greyed ones; the backfill grid's cloud-only tile, which gets *"no circle at all… an
    /// affordance offering to select it would be a control that lies"*; `Toggle`: *"a control
    /// refused at the system level is replaced by a sentence"*; `Buttons`: *"a disabled primary is
    /// **waiting**, not broken"*, which is not what this is; and `LockedPromptCard`, which is a
    /// card in its own vocabulary rather than a dimmed `PromptCard`.
    var verbs: [AddToArchiveVerb] {
        mayAddMedia ? AddToArchiveVerb.allCases : AddToArchiveVerb.allCases.filter { !$0.addsMedia }
    }

    /// **True in every authorization state, and false only where the row would lead nowhere.**
    ///
    /// The two clauses are different rules and the doc above says why they must not be merged.
    /// Asserted rather than assumed — the defect this replaced was exactly a case-analysis bug, so
    /// the four authorization cases are still a test, now run on both sides of `mayAddMedia`.
    ///
    /// Browsing the camera roll files photographs into the archive; it is the slowest of the
    /// media verbs rather than an exception to them.
    var includesCameraRoll: Bool { mayAddMedia }

    /// The call to action, in the slot the camera roll had. Never both.
    var includesMembership: Bool { !mayAddMedia }

    var cameraRollTitle: String { "Browse your camera roll" }

    /// §2's approved verb, unchanged, and the same one the Settings card and the locked cards use.
    /// A person **joins**.
    var membershipTitle: String { MembershipCopy.primaryAction }

    /// **⚠️ Not approved copy.** See `MembershipCopy.mediaIncluded` and *Proposed additions* §10 in
    /// `docs/design/free-tier-copy.md`.
    var membershipSubtitle: String { MembershipCopy.mediaIncluded }

    /// Factual, and never a tally.
    ///
    /// "62 photos from October 2025" is a count of what is in the camera roll; "you've missed six
    /// months" would be an accusation, and the app does not keep that score.
    ///
    /// **A count is only ever stated when it is a complete one.** Under `.limited` the scan can
    /// see the selected photos and nothing else, so a month total computed over them is a
    /// fraction presented as a whole — the same failure shape as a photo filed under the wrong
    /// day, and invisible in exactly the same way. So the limited copy says whose photos it
    /// counted, in the same breath as the number.
    var cameraRollSubtitle: String {
        switch authorization {
        case .denied:
            // One honest sentence. No retry funnel — iOS asks once and the flow behind this row
            // offers Settings, which is the only thing that can actually change the answer.
            return "Photo access is off. Everything else works exactly as it did."
        case .notDetermined:
            // Nothing has been scanned, so nothing is counted. This is an invitation, not a
            // report, and it is the sentence that leads to the explainer.
            return "Look back through the months you haven't written about yet."
        case .limited:
            guard let offer else {
                return "Browsing the photos you've shared with Pocket Chronicle."
            }
            return "\(Self.photos(offer.assetCount)) from \(offer.month.label()), "
                + "out of the photos you've shared."
        case .authorized:
            guard let offer else {
                // Every month with photos already has something written in it. A success, and it
                // does not need a number to say so.
                return "Wander back through any month."
            }
            return "\(Self.photos(offer.assetCount)) from \(offer.month.label()), nothing logged."
        }
    }

    private static func photos(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }
}

/// The sheet behind **+**.
///
/// **This replaced a one-tap composer, and that was a deliberate reversal** — see
/// `docs/decisions.md`. The camera roll is a browse action, not a fifth way to capture something,
/// and it needed a home where it could say what is actually waiting without sitting inside the
/// form someone opened to write. The cost is a tap on the way to every entry, which is the part
/// worth watching.
///
/// **Since phase 147 it is also where a household that cannot add media finds out**, and it says so
/// by offering what it can rather than by greying out what it cannot. Every decision about *which*
/// rows exist is in `AddToArchiveModel`; this view draws what it is handed.
struct AddToArchiveSheet: View {
    let model: AddToArchiveModel
    let onChoose: (AddToArchiveChoice) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The content's own height, which is what the sheet is sized to.
    ///
    /// Seeded rather than started at zero, and the seed is doing one job: it is the height of the
    /// **first frame**, before the real measurement arrives. Starting at zero means starting on
    /// some other detent — `.medium`, half the screen — and then resizing in front of the parent
    /// once the content has been measured, on a sheet that opens on the way to every entry the
    /// app records. Seeded close, the correction is a few points and invisible; the value that
    /// actually sizes the sheet is always the measured one, at whatever text size the phone is
    /// set to.
    @State private var contentHeight: CGFloat = 380

    var body: some View {
        // Scrollable rather than a fixed height: at the largest Dynamic Type sizes four labelled
        // tiles plus a two-line offer are considerably taller than the sheet, and a fixed detent
        // clips the backfill row off the bottom — the one row this sheet was reversed for.
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.canvas)
        .presentationDragIndicator(.visible)
        // **Sized to what is in it.** `.medium` is half the screen whatever the content is, and
        // this content is well under half a screen — so the sheet opened with a gulf of empty
        // cream under the tiles.
        //
        // **Not `.presentationSizing(.fitted)`**, which is the modifier this looks like it wants:
        // a `ScrollView` has no intrinsic height, so `.fitted` sizes it to the *proposal* and
        // produces a near-full-screen sheet — measured, and worse than the `.medium` it replaced.
        // `.large` stays in the set for the accessibility text sizes, where the content genuinely
        // does exceed the screen and the sheet needs somewhere to grow.
        .presentationDetents([.height(contentHeight), .large])
    }

    /// The sheet's content without its `ScrollView`, **for the screenshot harness only**.
    ///
    /// `body` cannot be rendered: `ImageRenderer` will not rasterize a `ScrollView`, and the hosted
    /// render needs a view with an intrinsic height. Same seam, same reason, as
    /// `PaywallSheet.renderable`.
    var renderable: some View { content }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to the archive")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .padding(.bottom, 14)

            // **One column when there is one verb, two when there are four.** A 2×2 grid holding a
            // single tile leaves a tile-shaped hole beside it, which is a dimmed control drawn in
            // cream — the exact reading the set-shrinking rule exists to avoid. `CaptureChoices`
            // already does this: an audio prompt gets one full-width Record tile.
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.verbs) { verb($0) }
            }

            // Below a divider, and not a fifth tile in the grid. The divider is the design's way
            // of saying this is a different kind of thing from the verbs above it — which is as
            // true of the membership row as it was of the camera roll it stands in for.
            Divider()
                .overlay(Color.border)
                .padding(.top, 18)

            if model.includesCameraRoll { backfillRow }
            if model.includesMembership { membershipRow }
        }
        .padding(Layout.screenMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        model.verbs.count > 1
            ? [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            : [GridItem(.flexible())]
    }

    private func verb(_ verb: AddToArchiveVerb) -> some View {
        Button {
            choose(.compose(verb.opening))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: verb.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.terracotta)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.terracottaSoft,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                Text(verb.label)
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(TapScaleButtonStyle())
    }

    /// The door to the browse flow.
    ///
    /// Tapping it always enters `BackfillFlowView`, which reads the authorization status itself
    /// and opens on the screen that state calls for — the explainer, the limited-access screen,
    /// the no-access screen, or the suggestions. Nothing is decided twice.
    private var backfillRow: some View {
        Button {
            choose(.backfill)
        } label: {
            // Top-aligned, not centred. At the largest Dynamic Type sizes the offer runs to four
            // lines and a centred icon floats out beside the middle of the sentence, reading as a
            // stray mark rather than as the row's own glyph.
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.terracotta)
                    .frame(width: 44, height: 44)
                    .background(
                        Color.terracottaSoft,
                        in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.cameraRollTitle)
                        .typeRole(.cardTitle)
                        .foregroundStyle(Color.ink)
                    Text(model.cameraRollSubtitle)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkFaint)
            }
            .padding(.top, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.cameraRollTitle). \(model.cameraRollSubtitle)")
        .accessibilityAddTraits(.isButton)
    }

    /// The way in, for a household the media verbs are not offered to.
    ///
    /// **Text only — no glyph and no chevron**, and both omissions are the approved design's own
    /// rulings rather than economies. The design drew a glyph on the lock's footer as treatment D
    /// and rejected it: *"A second mark 13pt below it says nothing the first one didn't… It also
    /// reads as the ring of a disabled control."* `LockedPromptCard` carries the same refusal for
    /// the chevron — *"a chevron promises navigation to content"* — and every other *Become a
    /// member* in the app, on the Settings card, is a `SettingsActionRow` with neither.
    ///
    /// `terracottaDeep` `#9A431E` rather than `terracotta`, which is the substitution phase 112 made
    /// at seven sites and `Notice` makes for its dismiss. On this sheet's `canvas` `#FDFAF4`,
    /// `terracotta` `#C05A2B` measures **4.25:1** (`design-system.md:298`) and `terracottaDeep`
    /// **6.31:1** (`Notice.swift`) — and a `cardTitle` label is not WCAG large text at every
    /// Dynamic Type setting, so it needs the 4.5:1 bar rather than 3:1.
    private var membershipRow: some View {
        Button {
            choose(.membership)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.membershipTitle)
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.terracottaDeep)
                Text(model.membershipSubtitle)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.membershipTitle). \(model.membershipSubtitle)")
        .accessibilityHint(MembershipCopy.lockedHint)
        .accessibilityAddTraits(.isButton)
    }

    private func choose(_ choice: AddToArchiveChoice) {
        dismiss()
        onChoose(choice)
    }
}

#if DEBUG
#Preview("Add to the archive — entitled") {
    Color.canvas.sheet(isPresented: .constant(true)) {
        AddToArchiveSheet(model: AddToArchiveModel(authorization: .authorized)) { _ in }
    }
}

/// The whole of phase 147, in one picture: Write stays, the three media verbs are not drawn at
/// all, and the row that offered the camera roll offers membership instead.
#Preview("Add to the archive — media is membership") {
    Color.canvas.sheet(isPresented: .constant(true)) {
        AddToArchiveSheet(
            model: AddToArchiveModel(authorization: .authorized, mayAddMedia: false)
        ) { _ in }
    }
}

#Preview("Add to the archive — media is membership, AX3") {
    Color.canvas.sheet(isPresented: .constant(true)) {
        AddToArchiveSheet(
            model: AddToArchiveModel(authorization: .authorized, mayAddMedia: false)
        ) { _ in }
        .environment(\.dynamicTypeSize, .accessibility3)
    }
}
#endif
