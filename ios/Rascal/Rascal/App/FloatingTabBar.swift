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
struct FloatingTabBar: View {
    @Binding var selection: Tab
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                if tab == .create {
                    createButton
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
        .padding(.horizontal, Layout.screenMargin)
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

    /// Raised slightly out of the capsule, per the reference.
    private var createButton: some View {
        Button(action: onCreate) {
            Image(systemName: Tab.create.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.surface)
                .frame(width: 52, height: 52)
                .background(Color.terracotta, in: Circle())
                .shadow(color: .terracotta.opacity(0.28), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(TapScaleButtonStyle())
        .frame(maxWidth: .infinity)
        .offset(y: -10)
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
