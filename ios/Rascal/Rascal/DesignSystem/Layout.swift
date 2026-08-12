import SwiftUI

/// Shape, spacing, and elevation from `docs/design-system.md`.
///
/// The shadow is deliberately almost invisible: warmth comes from the cream canvas, not from
/// depth. Anything heavier drifts toward the art-directed direction that was rejected twice.
enum Layout {
    /// Card corner radius.
    static let cardRadius: CGFloat = 20
    /// Photos and media sit inset with rounded corners; they rarely bleed to the screen edge.
    static let mediaInsetRadius: CGFloat = 14
    /// The hero block at the top of Entry Detail — one step softer than a card, because it is
    /// the largest shape on the screen and 20 reads as a bubble at that size.
    static let heroRadius: CGFloat = 18
    /// A quoted prompt on Entry Detail, where it is a filled block rather than a rule.
    static let quoteBlockRadius: CGFloat = 16

    /// Entry Detail's reading sheet — the cream surface that carries everything that is not the
    /// artifact.
    ///
    /// **26, which is what the design file draws.** This was 24, on the argument that it kept the
    /// radius on a 4pt step and was indistinguishable anyway. The second half of that is true and
    /// the first half is not a rule this file actually holds — `heroRadius` is 18, `quoteBlockRadius`
    /// 16, `glyphTile` 11 and 10. There was no step to stay on, so the file's number wins.
    static let sheetRadius: CGFloat = 26

    /// The grabber above a sheet's content: 38 × 5, centred, 14 clear beneath it.
    ///
    /// A sheet the parent can drag has to say so before they touch it, and this is the one shape
    /// in the app that says it. Not in `docs/design-system.md` yet — proposed there in this
    /// pass's report rather than added silently.
    enum Grabber {
        static let width: CGFloat = 38
        static let height: CGFloat = 5
        static let clearance: CGFloat = 14
    }

    /// A floating chrome control over an artifact — the back chip, the overflow, the expand.
    ///
    /// 40pt is the drawn circle; the tap target is brought back to 44 at the use site. Also not
    /// yet in `docs/design-system.md`, and proposed there rather than added silently.
    enum Chrome {
        static let diameter: CGFloat = 40
        static let tapTarget: CGFloat = 44
        /// Down from the top safe area, and in from the sides.
        static let inset: CGFloat = 16
    }

    static let borderWidth: CGFloat = 1

    /// Internal card padding.
    static let cardPadding: CGFloat = 16
    /// Horizontal screen margin.
    static let screenMargin: CGFloat = 16
    /// Between cards.
    static let cardSpacing: CGFloat = 12

    enum Shadow {
        static let y: CGFloat = 2
        static let blur: CGFloat = 8
        static let opacity: Double = 0.04
    }
}

/// Generic over its fill so a sealed letter can be washed with a gradient through the same
/// modifier every other card uses. One card shape, one shadow, one place to change them.
private struct CardSurface<Fill: ShapeStyle>: ViewModifier {
    let fill: Fill
    let border: Color

    func body(content: Content) -> some View {
        content
            .padding(Layout.cardPadding)
            .background(fill, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: Layout.borderWidth)
            )
            // SwiftUI's radius is roughly half a designer's blur.
            .shadow(
                color: .ink.opacity(Layout.Shadow.opacity),
                radius: Layout.Shadow.blur / 2,
                x: 0,
                y: Layout.Shadow.y
            )
    }
}

extension View {
    /// The standard card: padding, tinted fill, hairline border, barely-there shadow.
    ///
    /// `border` defaults to the cream-tuned hairline. A tinted card wants its own — the neutral
    /// line reads as a smudge against sage, and as dirt against the sealed wash.
    func cardSurface(fill: Color = .surface, border: Color = .border) -> some View {
        modifier(CardSurface(fill: fill, border: border))
    }

    /// The same card, washed rather than filled. Sealed letters only — the gradient is reserved
    /// for emotional beats and is never a background for ordinary content.
    func cardSurface(wash: LinearGradient, border: Color) -> some View {
        modifier(CardSurface(fill: wash, border: border))
    }
}

/// Capsule, 13pt. Metadata chips are a soft tint with no border; filter chips carry one.
struct Chip: View {
    let text: String
    var foreground: Color = .inkMuted
    var background: Color = .surface
    var bordered: Bool = false
    /// Semibold and a touch wider, for the tinted chips along the bottom of an `EntryCard`.
    /// Off everywhere else, so the timeline's v3 weight does not restyle Today and Settings
    /// on its way past.
    var emphasis: Bool = false

    var body: some View {
        Text(text)
            .typeRole(.metadata)
            .fontWeight(emphasis ? .semibold : .regular)
            .foregroundStyle(foreground)
            .padding(.horizontal, emphasis ? 11 : 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .overlay {
                if bordered {
                    Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                }
            }
    }
}

/// A row of chips that **wraps rather than clipping or truncating.**
///
/// An `HStack` of chips is right until the text scales or the archive has four tags, at which
/// point the last chip is cut in half — and a truncated chip reads as a rendering fault rather
/// than as a tag. That is the same failure `PromptCard`'s footer stacks vertically to avoid.
///
/// A `Layout` rather than a chunked `VStack` of `HStack`s, because chip widths are not known
/// until they are measured, and a hand-chunked version has to guess them.
///
/// **`SwiftUI.Layout` spelled out, and it has to be.** This file's own `enum Layout` shadows the
/// protocol inside this module, so the bare name resolves to the token enum and the conformance
/// fails with "inheritance from non-protocol type". The same trap waits for anything else in this
/// codebase that ever writes a custom layout.
struct FlowRow: SwiftUI.Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            // A chip wider than the row on its own still gets its own row rather than none —
            // it overflows visibly, which is a thing somebody can see and fix.
            if !current.indices.isEmpty, extended > width {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// The kind badge on a `PromptCard` — "PHOTO", "VOICE", "ACTIVITY". Small caps, not a chip.
struct KindBadge: View {
    let kind: String
    let tint: Color

    var body: some View {
        Text(kind)
            .typeRole(.label)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Capsule primary action. Terracotta for missions and primary, periwinkle for questions.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .terracotta
    /// Full-bleed by default, which is what every sheet and form in the app wants. A `PromptCard`
    /// sets this false: its action sits at the trailing end of a row beside the slot's name, and a
    /// button stretched across the card there would swallow the line it is meant to sit next to.
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeRole(.cardTitle)
            .foregroundStyle(Color.surface)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(configuration.isPressed ? Color.terracottaDeep : tint, in: Capsule())
            .contentShape(Capsule())
    }
}
