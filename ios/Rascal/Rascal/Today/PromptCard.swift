import SwiftUI

/// Today's mission or question.
///
/// Tinted by kind, because colour carries meaning here: terracotta for missions and
/// photo/video, periwinkle for questions and voice. A question card tinted terracotta
/// "because it's the brand colour" is a defect, not a style choice.
struct PromptCard: View {
    let assignment: AssignmentResponse
    let onPrimary: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(assignment.body)
                .typeRole(.promptBody)
                .foregroundStyle(isDone ? Color.inkMuted : Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !isDone {
                Button(assignment.completion.actionText, action: onPrimary)
                    .buttonStyle(PrimaryButtonStyle(tint: tint))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(fill: fill)
        .contentShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
        .contextMenu {
            if !isDone {
                Button("Not for us", systemImage: "xmark.circle", action: onDismiss)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isDone ? "" : assignment.completion.actionText)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            KindBadge(kind: assignment.promptKind.badgeText, tint: tint)

            if let expiry = expiryText {
                // Quiet, inkMuted, never red. Expiry is stated plainly and never scolds.
                Chip(text: expiry)
            }

            Spacer(minLength: 0)

            if isDone {
                CompletionCheck(isComplete: true, diameter: 24)
            }
        }
    }

    // MARK: Presentation

    private var isDone: Bool { assignment.status == .done }

    /// An unrecognised slot or kind renders as a neutral surface card with its body intact —
    /// an unknown value from a future server release is never a crash and never a blank card,
    /// and it is never given a guessed tint either.
    private var isRecognised: Bool {
        if case .unknown = assignment.slotKind { return false }
        if case .unknown = assignment.promptKind { return false }
        return true
    }

    private var tint: Color {
        guard isRecognised else { return .inkMuted }
        return assignment.slotKind.isQuestion || assignment.promptKind == .question
            || assignment.promptKind == .audio ? .periwinkle : .terracotta
    }

    private var fill: Color {
        if isDone { return .sage }
        guard isRecognised else { return .surface }
        return tint == .periwinkle ? .periwinkleSoft : .terracottaSoft
    }

    /// "2 days left", within three days of expiry. Nothing counts down before that, and
    /// nothing turns red at any point.
    private var expiryText: String? {
        guard !isDone, let days = assignment.daysUntilExpiry, days <= 3 else { return nil }
        switch days {
        case ..<0: return nil
        case 0: return "Last day"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }

    private var accessibilityText: String {
        var parts = [assignment.promptKind.badgeText, assignment.body]
        if let expiryText { parts.append(expiryText) }
        if isDone { parts.append("Done") }
        return parts.joined(separator: ". ")
    }
}

extension AssignmentResponse {
    /// Days from the child's today until expiry. The dates are server-computed in the child's
    /// timezone; this only measures between two of them and never decides what "today" is.
    var daysUntilExpiry: Int? {
        guard let expiresOn, let expiry = Self.dayFormatter.date(from: expiresOn) else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateComponents([.day], from: today, to: expiry).day
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
