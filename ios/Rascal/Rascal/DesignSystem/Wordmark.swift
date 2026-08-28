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
    /// **The drawn mark's ink height at `width` is `width × 126 / 531.5` — 24.65pt at 104.** The
    /// SVG path is inset from its viewBox by half the stroke, so the viewBox *is* the ink box.
    /// That is the number the type has to match, and matching it is what `pointSize` does.
    static let designAspectRatio: CGFloat = 531.5 / 126

    /// Sized so the type's **ink** matches the drawn mark's ink, which is not the same thing as
    /// matching its line box — and getting that wrong is how this view has been wrong twice.
    ///
    /// **The factor is 1.337, and it is `1 / 0.75` for the same reason `admin/static/cards.js`
    /// uses 1.3.** A font's point size is its em; the ascender is roughly 0.75 of it. The drawn
    /// band was the ascender height — the path's tallest points were the two `l` stems at
    /// `y = -116.25` against a baseline at `-9.75`, 106.5 of the 126-unit viewBox — so filling
    /// the same band takes `height / 0.75`.
    ///
    /// **Measured with CoreText, `CTLineGetImageBounds` rather than `size()`**, at `width: 104`:
    ///
    /// | | point size | advance | ink height | line box |
    /// |---|---|---|---|---|
    /// | drawn mark | — | 104pt | **24.65pt** | — |
    /// | ~~first try, `× 0.92`~~ | 22.68 | 174pt | **16.97pt** — 31% short | 27.0pt |
    /// | this | **32.96** | **253.8pt** | **24.66pt** | 39.0pt |
    ///
    /// ~~*the drawn mark was 24.7pt and this one is 27.0pt, +2.3pt*~~ — **struck: that compared
    /// this view's LINE BOX against the drawn mark's INK BOX**, which is why a mark 31% smaller
    /// than its predecessor read as parity. Compare like with like.
    ///
    /// **It costs 14.35pt of layout height** (39.0pt line box against 24.65pt of drawn ink), and
    /// that is the number to check against a screen budget — not the ink.
    ///
    /// **It fits on one line.** 253.8pt against `screen − 2 × OnboardingLayout.margin`, which is
    /// **319pt** on the narrowest iPhone this app supports: `IPHONEOS_DEPLOYMENT_TARGET` is 18.6
    /// and `TARGETED_DEVICE_FAMILY` is iPhone, so the floor is a 375pt SE — not the 320pt an
    /// earlier version of this comment claimed. 65pt of margin.
    private var pointSize: CGFloat {
        width / WordmarkView.designAspectRatio * 1.337
    }

    var body: some View {
        Text("Pocket Chronicle")
            .font(.system(size: pointSize, weight: .bold, design: .rounded))
            .kerning(-0.4)
            // One line, always. A wordmark that wraps is a paragraph.
            .lineLimit(1)
            // The guard, not the plan: shrink rather than truncate if a longer name or a
            // different font ever eats the 65pt of margin the measurement above found. It does
            // not engage on any shipping device, which is the point of saying so.
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
