import SwiftUI

/// Every colour in the app, taken verbatim from `docs/design-system.md`.
///
/// Two rules this file exists to enforce. Never pure black and never pure white — the ink is
/// navy-charcoal and the canvas is cream, and `#000`/`#FFF` appear nowhere. And colour carries
/// meaning rather than decoration: terracotta is missions and photo/video, periwinkle is
/// questions and voice, sage is did-it. Tinting a question card terracotta "because it's the
/// brand colour" is a defect, not a style choice.
extension Color {

    // MARK: Primary — missions, photo/video, primary action, the FAB

    static let terracotta = Color(hex: 0xC05A2B)
    static let terracottaSoft = Color(hex: 0xFBEDE2)
    static let terracottaDeep = Color(hex: 0x9A431E)

    // MARK: Secondary — questions, voice, waveforms

    static let periwinkle = Color(hex: 0x5566D6)
    static let periwinkleSoft = Color(hex: 0xE9EBFB)
    /// The hairline around a periwinkle-filled block — the voice hero on Entry Detail. `border`
    /// is a cream-tuned line and reads as grey dirt on periwinkle.
    static let periwinkleBorder = Color(hex: 0xDADDF7)

    // MARK: Ink

    static let ink = Color(hex: 0x23253C)
    static let inkMuted = Color(hex: 0x6E6A63)

    // MARK: Ground

    static let canvas = Color(hex: 0xFDFAF4)
    static let surface = Color(hex: 0xFFFDF9)
    static let border = Color(hex: 0xEDE5DA)

    /// The third step down the ink ramp, below `inkMuted`. Weekday labels, the closing line at
    /// the bottom of the archive, the date above a quoted prompt — text that is present but is
    /// never the thing being read.
    static let inkFaint = Color(hex: 0xB4ADA3)

    /// Did-it entries — the completion shape that produces no artifact.
    static let sage = Color(hex: 0xE8F0E6)
    /// The hairline around a sage card. `border` is tuned for cream and reads as a smudge here.
    static let sageBorder = Color(hex: 0xD8E4D5)
    /// The completion check, and the ink on a did-it chip.
    static let sageInk = Color(hex: 0x4B7A4F)
    /// Chip fill on a did-it card — a step darker than `sage`, because sage on sage is not a chip.
    static let sageSoft = Color(hex: 0xDCE8DA)

    /// The hairline around a sealed letter, which is washed rather than filled.
    static let sealedBorder = Color(hex: 0xF0DFD5)
    /// Body text under the blur on a sealed card. Deliberately weak: the words are there and
    /// they are not for reading yet.
    static let sealedInk = Color(hex: 0xA79A92)

    /// Neutral chip fill — a tag, not a kind. Warmer than `border`, which is a line colour.
    static let chipPlain = Color(hex: 0xF4EEE5)

    // MARK: Quote rules
    //
    // The 2pt rule down the left of a quoted prompt, tinted to the kind that prompt belongs to.
    // Same semantics as everywhere else — terracotta is missions and photo/video, periwinkle is
    // questions and voice, sage is did-it — held at rule strength so the quote stays quieter
    // than the entry it introduces.

    static let ruleTerracotta = Color(hex: 0xEBD8C8)
    static let rulePeriwinkle = Color(hex: 0xC6CCF2)
    static let ruleSage = Color(hex: 0xB7CDB3)
}

extension Color {
    /// `Color(hex: 0xC05A2B)`. Opaque; the palette has no translucent tokens.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Reserved for emotional beats only — onboarding, all-caught-up, throwback headers, sealed
/// entries. Diffuse and low contrast; it is never a background for ordinary content.
enum Gradients {
    static let wash = LinearGradient(
        colors: [Color(hex: 0xFDE8DC), Color(hex: 0xF7DDE8), Color(hex: 0xFBF6EF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
