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

    /// The width the mark is laid out to. Kept as the unit of size — rather than a font size — so
    /// the call sites that sized the drawn mark still read correctly, and so a future drawn mark
    /// can take over this API unchanged.
    var width: CGFloat = 104
    var tint: Color = .ink

    /// The drawn mark's aspect ratio, `531.5 × 126`. Retained as the basis for the type size, and
    /// **not** because the two occupy the same block — measured with CoreText at `width: 104`, the
    /// drawn mark was 24.7pt tall and this one is about 53pt over two lines, roughly **2.2×**.
    /// Swapping a drawn lockup back in *will* reflow the screen around it, and that is the honest
    /// statement; the welcome screen absorbs it today because a `Spacer()` sits above the mark.
    static let designAspectRatio: CGFloat = 531.5 / 126

    /// Chosen so the cap height lands near the drawn mark's stroke-inset height at the same width.
    ///
    /// **The lockup always stacks onto two lines, on every device.** Not an edge case on small
    /// phones — the frame below is a fixed `width`, independent of the screen, so the wrap is a
    /// property of the string and the size rather than of the hardware. Measured with CoreText at
    /// `width: 104` (pointSize 22.68): *"Pocket Chronicle"* on one line is 174pt, *"Pocket"* is
    /// 71pt and *"Chronicle"* is 99pt. So it wraps, and both lines fit — but *"Chronicle"* clears
    /// the frame by about 5pt, which is thin enough that `lineLimit` and `minimumScaleFactor`
    /// below are load-bearing rather than decorative: they turn a clipped mark into a slightly
    /// smaller one if a future font or a wider name eats that margin.
    private var pointSize: CGFloat {
        width / WordmarkView.designAspectRatio * 0.92
    }

    var body: some View {
        Text("Pocket Chronicle")
            .font(.system(size: pointSize, weight: .bold, design: .rounded))
            .kerning(-0.4)
            // Two lines, and never more — the name is two words. `minimumScaleFactor` is the
            // guard on the ~5pt of headroom the measurement above found: without it a wider
            // rendering of "Chronicle" clips at the frame instead of shrinking to fit.
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
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
