import SwiftUI

enum Tab: Int, CaseIterable, Identifiable {
    case today, timeline, create, moments, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .timeline: "Timeline"
        case .create: "New entry"
        case .moments: "Moments"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .timeline: "square.stack"
        case .create: "plus"
        case .moments: "sparkles"
        case .settings: "gearshape"
        }
    }
}

/// Capsule floating above the safe area, five slots, the centre `+` a filled terracotta circle
/// slightly raised. Straight from the reference layout in `docs/design-system.md`.
///
/// **The `+` is drawn above the capsule, not inside it.** It used to be the middle child of the
/// `HStack` the capsule's `.background` and `.overlay` are applied to — and an `.overlay` composites
/// above everything in the view it modifies, so `Capsule().strokeBorder(Color.border)` was drawn
/// *over the disc*. That is the faint pale ring across its top edge in the TestFlight screenshot:
/// not a stroke of the disc's own, but the bar's stroke passing over it. `offset(y: -10)` on a
/// 52pt disc inside 8pt padding also left it barely proud of a ~57pt capsule, so "slightly raised"
/// read as "sunk in".
///
/// Now the capsule is built and stroked first, and the disc is composited after it in a `ZStack`.
/// The middle slot holds an empty spacer so the four real tabs keep their fifths.
struct FloatingTabBar: View {
    @Binding var selection: Tab
    let onCreate: () -> Void
    /// The bar's measured height, reported so the scrolling screens behind it can inset by what
    /// is actually there rather than by a number kept in step by hand.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// How far the disc's top stands above the capsule's top edge.
    ///
    /// **Measured from the capsule's edge, not from its centre, and that is what makes it hold.**
    /// An `.offset` from the centre is a fixed distance between two centres, so it only produces
    /// a fixed *protrusion* while the capsule is a fixed height — and the capsule is not: its tab
    /// labels and glyphs scale with Dynamic Type. At the accessibility sizes a centre-relative
    /// lift would leave the disc entirely inside a taller capsule, which is the "sunk in" defect
    /// this phase fixed, returning for anyone who has ever enlarged their text.
    private static let protrusion: CGFloat = 14

    var body: some View {
        capsule
            // **After the capsule's own stroke, so nothing draws across the disc.** The bug this
            // replaced was precisely an `.overlay` compositing above the disc; this is the same
            // mechanism used in the right order.
            .overlay(alignment: .top) {
                createButton.offset(y: -Self.protrusion)
            }
            .padding(.horizontal, Layout.screenMargin)
            // The disc stands outside the capsule's frame, and `.offset` does not resize the box
            // it is in — so without this the bar would report a height stopping at the capsule
            // and the content behind would inset to just under the disc.
            .padding(.top, Self.protrusion)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                if tab == .create {
                    // The slot the disc sits over. Empty, so nothing in the capsule competes with
                    // the disc for the tap. It still claims its fifth, which is what keeps the
                    // four real tabs evenly spaced and the disc centred over the middle of five.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                } else {
                    tabButton(tab)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
        .shadow(color: .ink.opacity(0.06), radius: 10, x: 0, y: 4)
    }

    private func tabButton(_ tab: Tab) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18, weight: .medium))
                // Not the 12pt `.label` role: five labels plus a raised centre button do not
                // fit a capsule at that width, and "MOMENTS SETTINGS" ran together. The type
                // scale does not specify a tab bar, so this is the most restrained thing
                // consistent with it — same uppercase treatment, two points smaller, tracking
                // eased off, and it still scales with Dynamic Type.
                Text(tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selection == tab ? Color.terracotta : Color.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? [.isSelected, .isButton] : .isButton)
    }

    /// Raised out of the capsule, per the reference — and with a ring it means to have.
    ///
    /// The cream ring is `canvas`, deliberately: the disc sits over both the capsule's `surface`
    /// and the page behind it, and a ring in the page's own colour is what separates the two.
    /// What the screenshot showed instead was the capsule's `border` stroke drawn across the top
    /// of the disc — a ring by accident, in the wrong colour, on one edge only.
    ///
    /// The shadow is the design system's, not a heavier one invented for this control:
    /// `y: 2, blur: 8, opacity: 0.04` — "warmth comes from the cream, not from depth". The
    /// terracotta-tinted `radius: 8, y: 4, opacity: 0.28` that was here is a glow, and the system
    /// has no such token.
    ///
    /// 52pt across, so the tap target clears 44 with the ring to spare, and the middle capsule
    /// slot behind it is empty so nothing else claims the touch.
    private var createButton: some View {
        Button(action: onCreate) {
            Image(systemName: Tab.create.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.surface)
                .frame(width: 52, height: 52)
                .background(Color.terracotta, in: Circle())
                .padding(4)
                .background(Color.canvas, in: Circle())
                .shadow(color: .ink.opacity(0.04), radius: 8, x: 0, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel(Tab.create.title)
    }
}

/// Timeline, Moments, and Settings are deliberately inert this phase. They say so plainly
/// rather than pretending to be empty states of something that exists.
struct PlaceholderScreen: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text(tab.title)
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text("Coming in a later phase.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}
