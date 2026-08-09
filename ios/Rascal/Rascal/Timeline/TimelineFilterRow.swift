import SwiftUI

/// The filter row: All · Photos · Video · Voice · Written · Did it.
///
/// Active is solid terracotta with cream text, inactive is surface with a hairline border —
/// `docs/design-system.md`, Chip. It scrolls horizontally because six capsules do not fit across
/// a phone at 13pt with Dynamic Type turned up, and truncating one is worse than scrolling.
struct TimelineFilterRow: View {
    let selection: TimelineFilter
    let onSelect: (TimelineFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TimelineFilter.allCases) { filter in
                    chip(filter)
                }
            }
            .padding(.horizontal, Layout.screenMargin)
            .padding(.vertical, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter the archive")
    }

    private func chip(_ filter: TimelineFilter) -> some View {
        let isActive = filter == selection
        return Button {
            onSelect(filter)
        } label: {
            Text(filter.title)
                .typeRole(.metadata)
                .foregroundStyle(isActive ? Color.surface : Color.inkMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isActive ? Color.terracotta : Color.surface, in: Capsule())
                .overlay {
                    if !isActive {
                        Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }
}
