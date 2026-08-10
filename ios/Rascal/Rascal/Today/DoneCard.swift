import SwiftUI

/// Something finished today.
///
/// **Done keeps its kind.** The tint is the one the card carried while it was still a prompt, so a
/// completed question is still visibly a question — finishing does not change what it was. Sage is
/// the exception and stays reserved for `did_it`, where it is not decoration: it marks the
/// completion shape that produces no artifact, which is the one the archive most under-values.
struct DoneCard: View {
    let item: TodayBoard.BoardItem
    /// When it actually happened, from the local entry. **`occurred_at`, never `created_at`** — a
    /// backdated entry says the evening it belongs to, not the evening it was typed.
    ///
    /// Nil for a row the server acknowledged with no local entry behind it: completed on the other
    /// parent's phone, or before this install. Those rows say what was done and stay quiet about
    /// when, which is better than guessing.
    var completedAt: Date?
    var onEdit: (() -> Void)?
    /// Files on this entry that need a decision.
    ///
    /// **These have to live here.** `TodayBoard.merge` routes every item with a local entry into
    /// `done_today`, so a locally-completed mission is *always* a done card — which means this is
    /// the only card a failed upload can ever appear on. Handing `failures` to `PromptCard` alone
    /// puts the app's one retry affordance on a code path that cannot be reached.
    var failures: [Media] = []
    var onRetry: (Media) -> Void = { _ in }
    var onRetryAll: () -> Void = {}

    private var assignment: AssignmentResponse { item.assignment }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let onEdit {
                Button(action: onEdit) { row }
                    .buttonStyle(TapScaleButtonStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityHint("Edit this entry")
            } else {
                row
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityText)
            }

            if !failures.isEmpty {
                FailedUploadList(failures: failures, onRetry: onRetry, onRetryAll: onRetryAll)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 13) {
            completionMark

            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.body)
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.leading)
                    // The design clamps this to one line. Two, because at accessibility sizes one
                    // line of a long prompt is three words and an ellipsis.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(metaText)
                    .typeRole(.metadata)
                    // `inkMuted`, not `inkFaint`. The ink ramp's third step is for a weekday or an
                    // eyebrow date on the cream canvas; on a tinted card fill it drops to roughly
                    // 1.9:1, which is not readable. `design-system.md` names `inkMuted` for
                    // metadata anyway.
                    .foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous)
                .strokeBorder(border, lineWidth: Layout.borderWidth)
        )
    }

    /// A check only once there is nothing still in flight.
    ///
    /// The card is done the instant the parent saves — that is the local-over-server rule and it
    /// stays. But the *files* may not be, and a finished checkmark over three photos still climbing
    /// out of the phone is the card telling a comfortable lie. While bytes are moving this is the
    /// same byte-weighted ring `PromptCard` uses, so the two cards report the same fact the same way.
    @ViewBuilder
    private var completionMark: some View {
        if let progress = item.mediaProgress, !progress.isFinished {
            UploadRing(
                fraction: progress.fraction,
                remaining: progress.remaining,
                isComplete: false,
                diameter: 26
            )
        } else {
            CompletionCheck(isComplete: true, diameter: 26, tint: checkTint, check: .surface)
        }
    }

    private var isDidIt: Bool { assignment.completion == .didIt }

    private var fill: Color { isDidIt ? .sage : assignment.softTint }

    private var border: Color { isDidIt ? .sageBorder : assignment.tintBorder }

    private var checkTint: Color { isDidIt ? .sageInk : assignment.tint }

    /// "Photo · 4:12 PM", "Did it · 7:05 PM", "Written" when there is no local entry to date it.
    ///
    /// Rendered in the device's locale and the device's zone, which is right for this and not for a
    /// date. `occurred_at` is a genuine instant, so the phone in the parent's hand is the correct
    /// frame for "when did this happen"; `CalendarDay`'s fixed-UTC treatment exists for *days* the
    /// server named, where reading them locally would print the wrong day at UTC+14.
    private var metaText: String {
        guard let completedAt else { return assignment.completedDescription }
        let time = completedAt.formatted(date: .omitted, time: .shortened)
        return "\(assignment.completedDescription) · \(time)"
    }

    private var accessibilityText: String {
        var parts = [assignment.body, metaText, "Done"]
        if let progress = item.mediaProgress, !progress.isFinished {
            parts.append("\(progress.remaining) still uploading")
        }
        if !failures.isEmpty { parts.append("\(failures.count) not uploaded yet") }
        return parts.joined(separator: ". ")
    }
}

extension AssignmentResponse {
    /// What shape of thing landed: "Photo", "Voice", "Written", "Did it".
    ///
    /// Keyed off `completion_mode` rather than `kind`, because the mode is what the parent actually
    /// produced. A did-it mission and a photo mission are both missions; only one of them has a
    /// picture in it.
    var completedDescription: String {
        switch completion {
        case .didIt: "Did it"
        case .text: "Written"
        case .media: promptKind.badgeText
        case .unknown: "Saved"
        }
    }
}

#if DEBUG
private let previewTime = CalendarDay.parse("2026-08-11")

#Preview("Done cards") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            DoneCard(item: TodayPreview.item(.photo, done: true), completedAt: previewTime, onEdit: {})
            DoneCard(item: TodayPreview.item(.audio, done: true), completedAt: previewTime, onEdit: {})
            DoneCard(item: TodayPreview.item(.question, done: true), completedAt: previewTime, onEdit: {})
            DoneCard(item: TodayPreview.item(.didIt, done: true), completedAt: previewTime, onEdit: {})
            DoneCard(item: TodayPreview.item(.unknownKind, done: true), completedAt: previewTime, onEdit: {})

            SectionLabel("No local entry — completed elsewhere")
            DoneCard(item: TodayPreview.serverDone(.photo))

            SectionLabel("Long body")
            DoneCard(item: TodayPreview.item(.longBody, done: true), completedAt: previewTime, onEdit: {})
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
}

#Preview("Done cards — AX XXL") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            DoneCard(item: TodayPreview.item(.photo, done: true), completedAt: previewTime, onEdit: {})
            DoneCard(item: TodayPreview.item(.didIt, done: true), completedAt: previewTime, onEdit: {})
            DoneCard(item: TodayPreview.item(.longBody, done: true), completedAt: previewTime, onEdit: {})
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
