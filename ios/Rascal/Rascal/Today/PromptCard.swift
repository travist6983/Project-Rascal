import SwiftUI

/// Today's mission or question.
///
/// Tinted by kind, because colour carries meaning here: terracotta for missions and
/// photo/video, periwinkle for questions and voice. A question card tinted terracotta
/// "because it's the brand colour" is a defect, not a style choice.
struct PromptCard: View {
    let item: TodayBoard.BoardItem
    let onPrimary: () -> Void
    let onDismiss: () -> Void
    /// Set on done cards: tapping opens the composer in edit mode.
    var onEdit: (() -> Void)?
    var failures: [Media] = []
    var onRetry: (Media) -> Void = { _ in }
    var onRetryAll: () -> Void = {}

    private var assignment: AssignmentResponse { item.assignment }

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

            if !failures.isEmpty {
                FailedUploadList(failures: failures, onRetry: onRetry, onRetryAll: onRetryAll)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(fill: fill)
        .contentShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
        .onTapGesture {
            if isDone { onEdit?() }
        }
        .contextMenu {
            if !isDone {
                Button("Not for us", systemImage: "xmark.circle", action: onDismiss)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isDone ? (onEdit == nil ? "" : "Edit this entry") : assignment.completion.actionText)
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
                // Ring and check are one control: the ring fills as bytes land and closes
                // into the check drawing itself, so upload and completion read as one motion.
                UploadRing(
                    fraction: item.mediaProgress?.fraction ?? 1,
                    remaining: item.mediaProgress?.remaining ?? 0,
                    isComplete: item.mediaProgress?.isFinished ?? true,
                    diameter: 26
                )
            }
        }
    }

    // MARK: Presentation

    /// Local truth counts. An entry saved offline is done the instant it is saved; whether
    /// the server has heard is a fact about the network, not about the parent's evening.
    private var isDone: Bool { item.isDone }

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

    /// **Done keeps its kind.**
    ///
    /// Previously every done card went sage, which threw away the one thing the colour was
    /// carrying at the moment the card is most satisfying to look at: a completed question
    /// stopped being a question. The tint means mission-or-question; finishing does not change
    /// what it was.
    ///
    /// Sage stays for `did_it` specifically, where it is not decoration — it marks the
    /// completion shape that produces no artifact, which is the one the archive is most likely
    /// to under-value.
    private var fill: Color {
        if isDone, assignment.completion == .didIt { return .sage }
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
        if isDone {
            parts.append("Done")
            if let progress = item.mediaProgress, !progress.isFinished {
                parts.append("\(progress.remaining) still uploading")
            }
            if !failures.isEmpty { parts.append("\(failures.count) not uploaded yet") }
        }
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
