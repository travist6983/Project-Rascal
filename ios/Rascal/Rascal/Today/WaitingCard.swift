import SwiftUI

/// A pending assignment carried over from an earlier day.
///
/// Compact on purpose. These are the items a parent did not get to, and the design's whole
/// argument is that they should be present without being loud — a full `PromptCard` each would
/// turn a quiet backlog into a wall of unfinished work, which is the tone this app exists not to
/// have. Body clamps at two lines; the card that wants your attention today is the tall one.
///
/// **Presentational only.** The skip gesture lives on the list that owns the row, not here, so
/// VoiceOver gets a real rotor action instead of a swipe nobody can discover.
struct WaitingCard: View {
    let item: TodayBoard.BoardItem
    /// The child's today, server-computed. Used to measure expiry, never to decide what day it is.
    let today: String
    let onOpen: () -> Void

    private var assignment: AssignmentResponse { item.assignment }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                glyphTile

                VStack(alignment: .leading, spacing: 8) {
                    Text(assignment.body)
                        .typeRole(.body)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 7) {
                        KindBadge(kind: assignment.promptKind.badgeText, tint: assignment.tint)
                        if let chip = chipText { ExpiryChip(text: chip) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .foregroundStyle(Color.inkMuted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(assignment.completion.actionText)
    }

    /// Washed rather than filled, unlike the live card's tile. A compact row is furniture; a solid
    /// disc of terracotta on every one of eight of them reads as eight alarms.
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 30
    /// Scaled alongside the tile, for the same reason as `PromptCard`'s.
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var chevronSize: CGFloat = 12

    private var glyphTile: some View {
        Image(systemName: assignment.symbolName)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(assignment.tint)
            .frame(width: tileSize, height: tileSize)
            .background(
                assignment.tint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }

    /// Expiry first when there is one, because it is the only fact here with a deadline in it.
    /// Otherwise how long it has been waiting — stated, never scolded.
    private var chipText: String? {
        assignment.expiryLabel(asOf: today) ?? assignment.waitingSinceLabel(asOf: today)
    }

    private var accessibilityText: String {
        var parts = [assignment.promptKind.badgeText, assignment.body]
        if let chipText { parts.append(chipText) }
        return parts.joined(separator: ". ")
    }
}

extension AssignmentResponse {
    /// "Yesterday", "3 days ago" — how long this has sat.
    ///
    /// A fact, in the register of "4 waiting is a count, not an accusation". Nothing here counts
    /// up as a score and nothing past a week gets more specific, because "assigned 46 days ago" is
    /// an audit and this app does not audit anyone.
    func waitingSinceLabel(asOf today: String) -> String? {
        guard let assigned = CalendarDay.parse(assignedOn),
              let now = CalendarDay.parse(today)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let days = calendar.dateComponents([.day], from: assigned, to: now).day, days > 0
        else { return nil }

        switch days {
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        default: return "Earlier"
        }
    }
}

#if DEBUG
#Preview("Waiting card") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            WaitingCard(item: TodayPreview.item(.question), today: TodayPreview.today, onOpen: {})
            WaitingCard(item: TodayPreview.item(.photo), today: TodayPreview.today, onOpen: {})
            WaitingCard(item: TodayPreview.item(.audio), today: TodayPreview.today, onOpen: {})
            WaitingCard(item: TodayPreview.item(.didIt), today: TodayPreview.today, onOpen: {})
            WaitingCard(item: TodayPreview.item(.unknownKind), today: TodayPreview.today, onOpen: {})
            WaitingCard(item: TodayPreview.item(.longBody), today: TodayPreview.today, onOpen: {})
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
}

#Preview("Waiting card — AX XXL") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            WaitingCard(item: TodayPreview.item(.question), today: TodayPreview.today, onOpen: {})
            WaitingCard(item: TodayPreview.item(.longBody), today: TodayPreview.today, onOpen: {})
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
