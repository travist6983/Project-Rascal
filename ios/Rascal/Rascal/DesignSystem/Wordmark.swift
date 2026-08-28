import SwiftUI

/// The Pocket Chronicle wordmark — **type, not a drawn mark, and that is a stopgap.**
///
/// **What this used to be, because the reason it changed is the point.** Until Aug 27, 2026 this
/// file was 208 lines of Bézier geometry ported verbatim from `docs/app-icon/vellum-wordmark.svg`
/// (phase 70) — one monoline stroke with round caps, spelling *Vellum* in six letterforms across a
/// `531.5 × 126` viewBox. Drawn rather than set was the property that made it cheap: no font file
/// to embed, no licence to honour, nothing to go wrong between the design tool and the app, and
/// rule 4 satisfied without a vector asset format or a build step.
///
/// **Phase 130 retired the name that geometry spelled.** An attorney found a trademark conflict and
/// Vellum became Pocket Chronicle. The old path cannot be re-lettered: it is six glyphs, and the new
/// name is two words and sixteen characters. Condensing or stretching it would ship a lockup whose
/// proportions were drawn for a different word, which is worse than no lockup at all.
///
/// **So this sets the name as type at the display weight until a real lockup exists.** That is a
/// deliberate downgrade, not a finished design, and it is filed as owed design work rather than
/// quietly accepted. When a drawn mark arrives, this file goes back to being a `Shape` and the
/// call site does not change — which is why `WordmarkView(width:tint:)` keeps its signature.
///
/// **The name is never set in capitals** — owner's rule, Aug 18, 2026, recorded in
/// `docs/design-system.md`. Where the name is a mark, this view. Where it is a word in a sentence,
/// sentence case. There is no third option, and `VELLUM` was the spelling a case-sensitive rename
/// could not find — the reason that rule exists at all.
///
/// **It says "Pocket Chronicle", not "Chronicle".** This is the product's own signature on its first
/// screen, not an instruction to go find an icon, so it takes the full name. `Chronicle` is
/// `CFBundleDisplayName` and belongs only in copy naming a surface iOS renders.
struct WordmarkView: View {

    /// The width the *drawn* mark occupied, kept as the unit of size — rather than a font size —
    /// so the call sites still read correctly and a future drawn mark can take over this API
    /// unchanged. **It sizes the type; it no longer clamps it.** See `pointSize`.
    var width: CGFloat = 104
    var tint: Color = .ink

    /// The drawn mark's aspect ratio, `531.5 × 126`, kept as the basis for the type size.
    ///
    /// **Measured, not assumed** (CoreText, `width: 104`): the drawn mark was **24.7pt** tall and
    /// this one is **27.0pt** on a single line — `+2.3pt`, so swapping a drawn lockup back in
    /// barely moves the screen around it.
    static let designAspectRatio: CGFloat = 531.5 / 126

    /// Chosen so the cap height lands near the drawn mark's stroke-inset height at `width`.
    ///
    /// **The mark sets on ONE line and takes its natural width, which is wider than `width`.**
    /// That is the whole reason this reads as a lockup rather than a paragraph. At `width: 104`
    /// the point size is 22.68 and *"Pocket Chronicle"* measures **174pt × 27.0pt**; the drawn
    /// mark it replaced was 104pt × 24.7pt. Wider, and 2.3pt taller.
    ///
    /// **An earlier version of this view clamped the text to `.frame(width: width)`, which forced
    /// a two-line wrap and made the mark 53pt tall.** That is not a cosmetic difference: measured
    /// on an iPhone SE, the extra 29pt is what tipped `accessibility1` from fitting the welcome
    /// screen to overflowing it — and `WelcomeScreen` has no `ScrollView`, so an overflow there
    /// leaves the sign-in buttons unreachable. One line costs nothing and removes that entirely.
    ///
    /// **It fits.** 174pt against a content width of `screen − 2 × OnboardingLayout.margin`, which
    /// is 264pt on the narrowest device iOS still runs on (320pt logical) and 319pt on an SE.
    /// `minimumScaleFactor` below is the guard if a longer name or a different font ever eats
    /// that margin — it shrinks the mark rather than truncating it.
    private var pointSize: CGFloat {
        width / WordmarkView.designAspectRatio * 0.92
    }

    var body: some View {
        Text("Pocket Chronicle")
            .font(.system(size: pointSize, weight: .bold, design: .rounded))
            .kerning(-0.4)
            // One line, always. A wordmark that wraps is a paragraph.
            .lineLimit(1)
            // The guard, not the plan: shrink rather than truncate if a narrower screen or a
            // longer name ever eats the ~90pt of margin the measurement above found.
            .minimumScaleFactor(0.6)
            .foregroundStyle(tint)
            .accessibilityLabel("Pocket Chronicle")
    }
}

#if DEBUG
#Preview("Wordmark") {
    VStack(alignment: .leading, spacing: 28) {
        WordmarkView(width: 104)
        WordmarkView(width: 180)
        WordmarkView(width: 104, tint: .terracotta)
    }
    .padding(32)
}
#endif
