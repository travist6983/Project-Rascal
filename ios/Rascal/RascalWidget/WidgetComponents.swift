import SwiftUI
import WidgetKit

/// The pieces the Home Screen families are built from.

// MARK: - Prompt text that never breaks a word

/// A prompt, shortened until it fits, always on a whole word.
///
/// `ViewThatFits` measures the candidates in order and takes the first that does — which is what
/// makes this correct at every Dynamic Type size rather than at the one it was designed against.
/// `PromptText.wordSafe` supplies each candidate; its character budgets are only a way of
/// generating progressively shorter options, and being approximate is fine because the layout,
/// not the arithmetic, decides which one is used.
struct WordSafePrompt: View {
    let text: String
    let role: TypeRole
    var lineLimit: Int?

    /// Deliberately coarse, and written out rather than generated. `ViewThatFits` resolves its
    /// content as a fixed list of subviews; a `ForEach` inside it is one subview, not five
    /// candidates, and the whole mechanism quietly stops working.
    var body: some View {
        ViewThatFits(in: .vertical) {
            rendered(PromptText.wordSafe(text, within: 100))
            rendered(PromptText.wordSafe(text, within: 72))
            rendered(PromptText.wordSafe(text, within: 52))
            rendered(PromptText.wordSafe(text, within: 36))
            rendered(PromptText.wordSafe(text, within: 24))
            // The floor. Two words and an ellipsis fit anything the system asks a widget to draw
            // into, and it is still a whole word.
            rendered(PromptText.wordSafe(text, within: 14))
        }
    }

    private func rendered(_ value: String) -> some View {
        Text(value)
            .typeRole(role)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Rows

/// The small-caps kind label above a prompt — "MISSION", "QUESTION" — with its symbol.
///
/// The symbol is not decoration. It is the channel that survives the Lock Screen's monochrome
/// rendering, so it carries the same meaning here that colour carries on the Home Screen, and
/// the two surfaces stay one vocabulary.
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
    }
}

/// One prompt as it appears on the medium family: label, then the prompt's own words.
struct PromptRow: View {
    let featured: WidgetSnapshot.Featured
    let tint: Color
    var lineLimit: Int? = 3

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
            } else {
                WordSafePrompt(text: featured.item.body, role: .metadata, lineLimit: lineLimit)
                    .foregroundStyle(palette.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The two states with nothing to show

/// Stale and absent. Both are neutral, quiet, and never phrased as a problem.
///
/// **The stale case cannot render yesterday's prompt**, because `WidgetSnapshotState.stale`
/// carries only a first name. That is deliberate: the guarantee is structural rather than a rule
/// this view has to remember.
struct NeutralView: View {
    let name: String?
    var compact: Bool = false

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "book.closed")
                .font(.system(size: compact ? 14 : 18, weight: .regular))
                .foregroundStyle(palette.inkFaint)

            if let name, !name.isEmpty, !compact {
                Text(name)
                    .typeRole(.cardTitle)
                    .foregroundStyle(palette.ink)
            }

            Text(compact ? "Open for today" : "Open the app for today's prompts.")
                .typeRole(.metadata)
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Both prompts finished. Warm and quiet — no celebration graphic, no count of what was done.
struct CompleteView: View {
    let name: String

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(palette.done)

            Text(name.isEmpty ? "Both done today" : "\(name)'s day is written down")
                .typeRole(.cardTitle)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Nothing else waiting.")
                .typeRole(.metadata)
                .foregroundStyle(palette.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
