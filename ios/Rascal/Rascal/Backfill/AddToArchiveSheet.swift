import SwiftUI

/// What the **+** button asks for.
///
/// Deliberately a small enum rather than four closures: the sheet has to **dismiss before** any of
/// these can present, because presenting a sheet from a sheet that is on its way out drops the
/// second one. So the sheet records what was chosen, closes, and the root acts on it.
enum AddToArchiveChoice: Equatable {
    case compose(ComposerOpening)
    case backfill
}

/// What the **+** sheet shows, decided away from the view so all four authorization states can be
/// asserted rather than looked at.
///
/// **The camera-roll row is unconditional, and that is the whole point of this type.** It used to
/// be `if let offered` over the newest unlogged cluster, which read as a tidy "no row when there
/// is nothing to offer" — but clusters only exist once a scan has run, a scan only runs with
/// authorization, and the *only* place authorization is ever asked for is the explainer behind
/// this row. So on a phone that had never granted access the row was absent, which meant the
/// explainer was unreachable, which meant access was never granted, which meant the row stayed
/// absent. The feature was sealed behind its own door.
///
/// `docs/decisions.md` settles that **+** opens four capture verbs with the camera roll below a
/// divider as a fifth thing that is explicitly not a verb. That tap was paid on every entry; this
/// is the thing it bought.
nonisolated struct AddToArchiveModel: Equatable, Sendable {
    /// What the scan last saw. `.notDetermined` before one has run, which is the honest default:
    /// nothing has been counted, so nothing is claimed.
    let authorization: BackfillAuthorization
    /// The newest unlogged month, when there is one. Never gates the row — only its subtitle.
    let offer: BackfillCluster?

    init(authorization: BackfillAuthorization = .notDetermined, clusters: [BackfillCluster] = []) {
        self.authorization = authorization
        self.offer = clusters.first
    }

    /// **Always true, in every authorization state.** Asserted rather than assumed — the defect
    /// this replaced was exactly a case-analysis bug, so the four cases are a test.
    var includesCameraRoll: Bool { true }

    var cameraRollTitle: String { "Browse your camera roll" }

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
                return "Browsing the photos you've shared with Vellum."
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to the archive")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .padding(.bottom, 14)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                verb("Photo", symbol: "photo.on.rectangle", opening: .library)
                verb("Camera", symbol: "camera", opening: .camera)
                verb("Voice", symbol: "mic", opening: .recorder)
                verb("Write", symbol: "pencil", opening: .writing)
            }

            // Below a divider, and not a fifth tile in the grid. The divider is the design's way
            // of saying this is a different kind of thing from the four above it.
            Divider()
                .overlay(Color.border)
                .padding(.top, 18)
            backfillRow
        }
        .padding(Layout.screenMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verb(_ label: String, symbol: String, opening: ComposerOpening) -> some View {
        Button {
            choose(.compose(opening))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.terracotta)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.terracottaSoft,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                Text(label)
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

    private func choose(_ choice: AddToArchiveChoice) {
        dismiss()
        onChoose(choice)
    }
}
