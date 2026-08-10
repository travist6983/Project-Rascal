import SwiftUI
import WidgetKit

/// The pieces the Home Screen families are built from.
///
/// **The layout adapts, not just the text, and that is the lesson of the XXL screenshots.** The
/// first version shortened prompts and let the composition keep its ideal height; at
/// accessibility sizes a `systemMedium` needs 182pt of the 158pt it has, and the surplus simply
/// spilled out of the widget. Two labels, two prompts and a name do not fit in that box at
/// accessibility type, and no amount of shortening the sentences changes that.
///
/// So every family below is a `ViewThatFits` over *whole layouts* that give things up in order —
/// the name first, then a line of prompt, then the second prompt's words, then its label. Each
/// candidate has a deterministic height because its prompt is shortened to a fixed budget and
/// pinned with `fixedSize`, which is what lets `ViewThatFits` measure and choose honestly.

// MARK: - Text

/// A prompt shortened to a fixed budget, always on a whole word, and never cut by the layout.
///
/// `fixedSize` is deliberate: it forbids SwiftUI from squeezing the text and truncating it
/// mid-word behind our back. The height is therefore real, which is exactly what the enclosing
/// `ViewThatFits` needs in order to reject a candidate that does not fit.
struct PromptLine: View {
    let text: String
    let budget: Int
    var role: TypeRole = .metadata

    var body: some View {
        Text(PromptText.wordSafe(text, within: budget))
            .typeRole(role)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The small-caps kind label — "MISSION", "QUESTION" — with its symbol.
///
/// The symbol is not decoration. It is the channel that survives the Lock Screen's monochrome
/// rendering, so it carries there what colour carries on the Home Screen, and the two surfaces
/// stay one vocabulary.
///
/// Scaled rather than wrapped or truncated. At accessibility type "QUESTION" is wider than a
/// `systemSmall` widget, and a category marker reading "QUESTIO…" is worse than the same word
/// set smaller — this is the one place in the widget where shrinking beats shortening, because
/// there is no shorter way to say which of the two kinds this is.
struct SlotLabel: View {
    let label: String
    let symbol: String
    let tint: Color
    var isDone: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isDone ? "checkmark" : symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .typeRole(.label)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

/// One prompt as a row: its label, then its own words — or "Done", which does not repeat them.
struct PromptRow: View {
    let featured: WidgetSnapshot.Featured
    let tint: Color
    let budget: Int

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SlotLabel(
                label: featured.label,
                symbol: featured.item.symbolName,
                tint: featured.item.isDone ? palette.done : tint,
                isDone: featured.item.isDone
            )

            if featured.item.isDone {
                // A finished prompt does not repeat its own words. The parent answered it; the
                // widget saying it back is the archive talking about itself.
                Text("Done")
                    .typeRole(.metadata)
                    .foregroundStyle(palette.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                PromptLine(text: featured.item.body, budget: budget)
                    .foregroundStyle(palette.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element per row, reading as a sentence. The row is a `Link` on `systemMedium`, so
        // this is what a VoiceOver user activates to open that prompt specifically — the label,
        // the symbol and the prompt announced separately would be a pile, and hiding the row
        // entirely would be worse.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetNarration.line(for: featured))
    }
}

// MARK: - The states with nothing to show

/// Stale and absent. Both neutral, quiet, and never phrased as a problem.
///
/// **The stale case cannot render yesterday's prompt**, because `WidgetSnapshotState.stale`
/// carries only a first name. The guarantee is structural rather than a rule this view has to
/// remember.
struct NeutralView: View {
    let name: String?

    @Environment(\.palette) private var palette

    var body: some View {
        ViewThatFits(in: .vertical) {
            layout(showsGlyph: true, showsName: true)
            layout(showsGlyph: true, showsName: false)
            layout(showsGlyph: false, showsName: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func layout(showsGlyph: Bool, showsName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsGlyph {
                Image(systemName: "book.closed")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.inkFaint)
            }
            if showsName, let name, !name.isEmpty {
                Text(name)
                    .typeRole(.cardTitle)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text("Open for today's prompts")
                .typeRole(.metadata)
                .foregroundStyle(palette.inkMuted)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Both prompts finished. Warm and quiet — no celebration graphic, and no count of what was done.
struct CompleteView: View {
    let name: String
    /// The medium family can afford the warmer sentence; the small one cannot, at any type size.
    var roomy: Bool = false

    @Environment(\.palette) private var palette

    var body: some View {
        ViewThatFits(in: .vertical) {
            if roomy && !name.isEmpty {
                layout(headline: "\(name)'s day is written down", showsFooter: true)
                layout(headline: "\(name)'s day is written down", showsFooter: false)
            }
            layout(headline: "All done", showsFooter: true)
            layout(headline: "All done", showsFooter: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func layout(headline: String, showsFooter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(palette.done)

            Text(headline)
                .typeRole(.cardTitle)
                .foregroundStyle(palette.ink)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)

            if showsFooter {
                // No `lineLimit(1)`, deliberately. A one-line limit makes this candidate fit at
                // any type size — by truncating itself to "Nothing else waiti…" — so
                // `ViewThatFits` never reaches the fallback that drops it. Letting it wrap is
                // what makes its height honest and the choice above it correct.
                Text("Nothing else waiting.")
                    .typeRole(.metadata)
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
