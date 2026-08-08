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

    // MARK: Ink

    static let ink = Color(hex: 0x23253C)
    static let inkMuted = Color(hex: 0x6E6A63)

    // MARK: Ground

    static let canvas = Color(hex: 0xFDFAF4)
    static let surface = Color(hex: 0xFFFDF9)
    static let border = Color(hex: 0xEDE5DA)

    /// Did-it entries — the completion shape that produces no artifact.
    static let sage = Color(hex: 0xE8F0E6)
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
