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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeRole(.cardTitle)
            .foregroundStyle(Color.surface)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? Color.terracottaDeep : tint, in: Capsule())
            .contentShape(Capsule())
    }
}
