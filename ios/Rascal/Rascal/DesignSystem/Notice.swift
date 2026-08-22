import SwiftUI

/// A quiet note, never a dialog over the parent's evening.
///
/// `docs/design-system.md:298` has specified this component since the file was written —
/// *"`surface`, radius 14, `border` hairline, info glyph + a `metadata` line + a terracotta
/// Dismiss"* — and **it had no type.** Four screens carry a private, byte-for-byte copy:
/// `TodayBoardView.noticeBanner`, `MomentsScreen`, `EditProfileSheet` and `EditChildSheet`. This is
/// the specified component, given a name at last because phase 108 needed two more and a fifth copy
/// is where a spec stops being a spec.
///
/// **The four existing copies are deliberately not refactored here.** That is four screens' worth of
/// diff on a branch about something else, against a CI gate that lints all of `Rascal/`. The debt is
/// recorded in the phase's PR instead.
///
/// `cardSurface` cannot draw this: it is fixed at `Layout.cardRadius` (20) and adds a shadow. A
/// notice is 14 and flat, so the shape is hand-rolled — as all four copies do.
///
/// ## Two deliberate departures from `design-system.md:298`
///
/// **Padding is 14, not the 12 the four copies use.** The approved design specifies 14 for the
/// post-trial notice, and one component cannot have two paddings.
///
/// **The dismiss is `terracottaDeep`, not `terracotta`.** The spec says terracotta; `terracotta` on
/// canvas measures **4.25:1**, which fails AA for anything that is not large text, and this label is
/// 13pt. `terracottaDeep` is 6.31:1. Deepening the ink rather than restyling the control is the
/// substitution `KindBadge` already makes, for the same reason and with the same reasoning: colour
/// carries meaning here, and a dismiss that stopped reading as an action would trade an
/// accessibility defect for a semantic one.
struct Notice: View {
    let text: String

    /// The action that is not "go away", when there is one. Drawn first and semibold, so the row
    /// still has exactly one thing that looks like an action.
    var primaryLabel: String?
    var onPrimary: (() -> Void)?

    /// Nil for a notice that is not dismissible. **The membership sheet's products-unavailable row
    /// uses that**: it states what the screen can offer, and is not something to clear away.
    var onDismiss: (() -> Void)?
    var dismissLabel: String = "Dismiss"

    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: glyphSize))
                .foregroundStyle(Color.inkMuted)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    // Without this a notice of more than a line is truncated to one inside a `List`
                    // row — which is how the longest and most important sentence becomes the one
                    // nobody reads.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                actions
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            Color.surface,
            in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
        // **`.contain`, not `.combine`, and the difference is whether a VoiceOver user can act at
        // all.**
        //
        // `.combine` merges every child into one element. That is right for a view whose whole body
        // is a single button — `LockedPromptCard` uses it for exactly that reason — and wrong here:
        // this row can carry **two** actions, and merging them yields one element reading
        // "…See what's included Dismiss" with no way to invoke either. `.contain` groups them while
        // leaving each reachable.
        //
        // It is also what the tree already does for this shape: `OnboardingNotice` and `SkipToast`
        // both contain rather than combine.
        .accessibilityElement(children: .contain)
    }

    /// **Under the copy, not on its trailing edge.**
    ///
    /// The approved design is explicit about why: *"at AX sizes a three-line sentence plus two
    /// labels on one row cannot fit 361pt."* A single dismiss could sit inline; two cannot, and one
    /// component with two layouts is a component that gets the rarer one wrong.
    @ViewBuilder
    private var actions: some View {
        if primaryLabel != nil || onDismiss != nil {
            // **`ViewThatFits`, for the reason `PromptCard.footer` has one.** Two labels on one row
            // do not fit a 361pt notice at accessibility sizes — "See what's included" alone is
            // wider than the row — and a clipped action reads as a rendering fault rather than as a
            // control. Falling back to a stack keeps both readable.
            ViewThatFits(in: .horizontal) {
                // The trailing `Spacer` belongs to this branch alone. In the stacked fallback it
                // would be a *vertical* spacer and would push the two labels apart to fill whatever
                // height was offered.
                HStack(spacing: 16) {
                    actionButtons
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 4) { actionButtons }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let primaryLabel, let onPrimary {
            Button(action: onPrimary) {
                Text(primaryLabel)
                    .typeRole(.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.terracottaDeep)
                    .tappable()
            }
        }
        if let onDismiss {
            Button(action: onDismiss) {
                Text(dismissLabel)
                    .typeRole(.metadata)
                    // Plain `inkMuted` when it sits beside an opener, so the row has one primary.
                    // `terracottaDeep` when it is the only control.
                    .foregroundStyle(primaryLabel == nil ? Color.terracottaDeep : Color.inkMuted)
                    .tappable()
            }
        }
    }
}

private extension View {
    /// A 13pt label is a **16pt tall tap target**, which is well under the 44 the HIG asks for and
    /// is genuinely hard to hit — especially "Dismiss", which a parent reaches for one-handed.
    ///
    /// **Applied inside a `Button`'s label, never to the `Button` itself**, and the first version of
    /// this got it wrong: a frame around the composed button centres the label in a 44pt box that
    /// belongs to the frame rather than to the control, so the row grew by 28pt and the hit area
    /// stayed 16pt — strictly worse than doing nothing. `EntryDetailScreen`'s chrome buttons, which
    /// this borrows `Layout.Chrome.tapTarget` from, put both modifiers inside the label for exactly
    /// this reason.
    ///
    /// Leading alignment because the stacked fallback wraps, and a centred wrap beside a
    /// leading-aligned sentence reads as a rendering fault.
    func tappable() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: Layout.Chrome.tapTarget, alignment: .leading)
            .contentShape(Rectangle())
    }
}

#if DEBUG
#Preview("Notice") {
    VStack(alignment: .leading, spacing: 12) {
        SectionLabel("Statement — no control")
        Notice(text: MembershipCopy.productsUnavailable)

        SectionLabel("Dismissible")
        Notice(text: "That prompt expired before it was answered.", onDismiss: {})

        SectionLabel("Two actions — the post-trial notice")
        Notice(
            text: MembershipCopy.postTrialNotice,
            primaryLabel: MembershipCopy.postTrialOpen,
            onPrimary: {},
            onDismiss: {},
            dismissLabel: MembershipCopy.postTrialDismiss
        )
    }
    .padding(Layout.screenMargin)
    .background(Color.canvas)
}

/// The size the two-action layout exists for — the design's stated reason for stacking.
#Preview("Notice — AX3") {
    VStack(alignment: .leading, spacing: 12) {
        Notice(
            text: MembershipCopy.postTrialNotice,
            primaryLabel: MembershipCopy.postTrialOpen,
            onPrimary: {},
            onDismiss: {},
            dismissLabel: MembershipCopy.postTrialDismiss
        )
        Notice(text: MembershipCopy.productsUnavailable)
    }
    .padding(Layout.screenMargin)
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
