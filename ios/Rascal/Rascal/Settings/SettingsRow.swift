import SwiftUI

/// The Settings vocabulary: a section label, a card of rows, and the rows themselves.
///
/// Settings is not a control panel. It is the same warm, quiet app one screen deeper, so these
/// use the shapes the rest of the app already uses — radius 20, `surface` fill, `border`
/// hairline, small-caps `inkMuted` section labels — rather than borrowing the system's grouped
/// list, which brings its own greys and its own register.

/// A group of rows sharing one card, divided internally.
///
/// One card per section rather than one per row, because a divider between two related settings
/// reads as "these belong together" and a gap reads as "these do not". That distinction is
/// load-bearing at the bottom of this screen, where the irreversible actions are deliberately
/// *not* in the same card as anything ordinary.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        // Cards are full-bleed inside the screen margin, always. Without this the card sizes to
        // its content, which is invisible for a row (its `Spacer` fills) and obvious the moment
        // a card holds a left-aligned stack instead — the export card rendered as a floating
        // box two-thirds of the way across the screen.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
        .shadow(
            color: .ink.opacity(Layout.Shadow.opacity),
            radius: Layout.Shadow.blur / 2,
            x: 0,
            y: Layout.Shadow.y
        )
    }
}

/// The hairline between two rows in a card. Inset to the text, not to the card edge, so the
/// rows read as a list rather than as stacked boxes.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.border)
            .frame(height: Layout.borderWidth)
            .padding(.leading, Layout.cardPadding)
    }
}

/// Label, trailing value, chevron. Tapping presents a sheet.
struct SettingsRow: View {
    let label: String
    var value: String?
    /// Set when the value is absent rather than empty — "Not provided" is words, and it is set
    /// in `inkMuted` so it does not read as content.
    var valueIsMuted: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .typeRole(.body)
                        .foregroundStyle(valueIsMuted ? Color.inkMuted : Color.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkMuted)
            }
            .padding(Layout.cardPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\(label), \($0)" } ?? label)
        .accessibilityAddTraits(.isButton)
    }
}

/// A row that reports rather than navigates: no chevron, no tap.
struct SettingsValueRow: View {
    let label: String
    let value: String
    var valueIsMuted: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            Text(value)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.trailing)
        }
        .padding(Layout.cardPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// A row that performs an action instead of drilling in — export, retry, recompute.
///
/// Terracotta because it is a thing you do, with the same restraint as everywhere else: no
/// filled button inside a list, and nothing red however irreversible the action is. Red is an
/// urgency state and this screen has none.
struct SettingsActionRow: View {
    let label: String
    /// One quiet line under the label saying what the action does, where that is not obvious.
    var detail: String?
    var isBusy: Bool = false
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .typeRole(.body)
                        .foregroundStyle(isEnabled ? Color.terracotta : Color.inkMuted)
                    if let detail {
                        Text(detail)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isBusy { ProgressView().tint(.terracotta) }
            }
            .padding(Layout.cardPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .disabled(!isEnabled || isBusy)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(label). \($0)" } ?? label)
        .accessibilityAddTraits(.isButton)
    }
}
