import SwiftUI

/// The palette, resolved for an appearance the app itself never has to face.
///
/// **"Light mode only" is settled for the app and cannot hold here.** A widget follows the system
/// appearance and has no way to opt out — there is no `preferredColorScheme` for a widget, and a
/// light card on a dark Home Screen is not a style choice, it is a bright rectangle in someone's
/// evening. So this is a scoped exception, recorded as one in `docs/decisions.md`: the widget
/// renders dark, and nothing else in the product does.
///
/// Two rules from `docs/design-system.md` survive the translation intact, because they are what
/// makes the dark rendering still look like this product rather than a generic dark theme:
///
///   * **Never pure black, never pure white.** The dark ground is a warm charcoal with a brown
///     cast, drawn down from the cream canvas rather than up from `#000`. The dark ink is a warm
///     off-white, not `#FFF`. Inverting to black and white was the obvious move and it reads as a
///     different app.
///   * **Colour carries meaning.** Terracotta is still missions, periwinkle is still questions.
///     Both are *lifted*, not swapped: `#C05A2B` on a dark ground fails contrast badly, so the
///     dark tokens are the same hues taken up in luminance until they carry at body size.
struct WidgetPalette {
    let canvas: Color
    let surface: Color
    let border: Color
    let ink: Color
    let inkMuted: Color
    let inkFaint: Color
    /// Missions, and the primary of the two.
    let mission: Color
    /// Questions, and voice.
    let question: Color
    /// A finished item. Sage, the did-it colour, in both appearances.
    let done: Color

    static func resolved(for scheme: ColorScheme) -> WidgetPalette {
        scheme == .dark ? .dark : .light
    }

    /// The app's own tokens, unchanged. The widget may not invent one the design system already
    /// defines.
    static let light = WidgetPalette(
        canvas: .canvas,
        surface: .surface,
        border: .border,
        ink: .ink,
        inkMuted: .inkMuted,
        inkFaint: .inkFaint,
        mission: .terracotta,
        question: .periwinkle,
        done: .sageInk
    )

    /// Derived from the light tokens rather than picked fresh: each is the same hue with its
    /// luminance moved, so the two appearances are the same palette seen in two lights.
    static let dark = WidgetPalette(
        // Warm charcoal. The cream canvas taken down, so it keeps the brown cast — a neutral
        // grey here is what makes a warm product look cold at night.
        canvas: Color(hex: 0x1F1C1A),
        surface: Color(hex: 0x2A2624),
        border: Color(hex: 0x3B3532),
        // Warm off-white, the counterpart to navy-charcoal ink on cream.
        ink: Color(hex: 0xF3ECE2),
        inkMuted: Color(hex: 0xB2A89D),
        inkFaint: Color(hex: 0x807771),
        // Terracotta and periwinkle lifted until they carry on the dark ground. Measured against
        // `surface`: roughly 5:1 and 6:1, which holds at body size and above.
        mission: Color(hex: 0xE28B5B),
        question: Color(hex: 0x9AA6F0),
        done: Color(hex: 0x8FB894)
    )
}

private struct WidgetPaletteKey: EnvironmentKey {
    static let defaultValue = WidgetPalette.light
}

extension EnvironmentValues {
    /// Read by every view below, so no view resolves the appearance itself and no view can
    /// accidentally render half in one palette and half in the other.
    var palette: WidgetPalette {
        get { self[WidgetPaletteKey.self] }
        set { self[WidgetPaletteKey.self] = newValue }
    }
}
