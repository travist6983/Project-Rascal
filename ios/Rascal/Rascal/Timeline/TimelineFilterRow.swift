import SwiftUI

/// The filter row: All · Photos · Video · Voice · Written · Did it · Sealed.
///
/// Active is solid terracotta with cream text, inactive is surface with a hairline border —
/// `docs/design-system.md`, Chip. It scrolls horizontally because seven capsules do not fit
/// across a phone at 13pt with Dynamic Type turned up, and truncating one is worse than
/// scrolling.
///
/// **Deliberately transparent.** It sits inside the timeline's sticky header, whose cream-over-
/// blur is what the archive scrolls behind; a background here would punch an opaque band
/// through it.
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
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                .fontWeight(.semibold)
                .foregroundStyle(isActive ? Color.canvas : Color.inkMuted)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(isActive ? Color.terracotta : Color.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        isActive ? Color.terracotta : Color.border,
                        lineWidth: Layout.borderWidth
                    )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }
}
