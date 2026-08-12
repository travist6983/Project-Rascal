import SwiftUI

/// Today's mission or question — the one card on the board that is asking for something.
///
/// Tinted by kind, because colour carries meaning here: terracotta for missions and photo/video,
/// periwinkle for questions and voice. A question card tinted terracotta "because it's the brand
/// colour" is a defect, not a style choice. The tint rules live on `AssignmentResponse` so the
/// compact cards below it cannot drift away from this one.
struct PromptCard: View {
    let item: TodayBoard.BoardItem
    /// The child's today, server-computed in `family_timezone`. Used to measure expiry and to know
    /// whether this was assigned today — never to decide what day it is.
    let today: String
    let onPrimary: () -> Void
    let onDismiss: () -> Void
    /// Set on done cards: tapping opens the composer in edit mode.
    var onEdit: (() -> Void)?
    var failures: [Media] = []
    var onRetry: (Media) -> Void = { _ in }
    var onRetryAll: () -> Void = {}

    /// The child this prompt is about, set once in `RootView` above every tab.
    @Environment(\.promptSubject) private var promptSubject
    @Environment(\.personalization) private var personalization
    @Environment(\.childAgeMonths) private var childAgeMonths

    private var assignment: AssignmentResponse { item.assignment }

    /// **The only place this card reads a prompt body.** One property so the card and its
    /// VoiceOver label cannot end up saying different sentences.
    /// Tokens first, then the model.
    ///
    /// **The order is the contract, not a preference.** `PromptTokens` is the exact, server-agreed
    /// substitution and it is authoritative; personalization is best-effort on whatever is left,
    /// and it is validated against this string rather than against the raw body. Personalizing
    /// first would hand the guard a sentence the app never intended to show.
    private var prompt: String {
        personalization.text(for: assignment.id, canonical: canonicalPrompt)
    }

    private var canonicalPrompt: String {
        PromptTokens.render(assignment.body, for: promptSubject)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text(prompt)
                .typeRole(.promptBody)
                .foregroundStyle(isDone ? Color.inkMuted : Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !isDone { footer }

            if !failures.isEmpty {
                FailedUploadList(failures: failures, onRetry: onRetry, onRetryAll: onRetryAll)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(fill: fill, border: border)
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
        // **The card is already drawn by the time this runs, and it stays drawn if this never
        // finishes.** `.task` rather than anything the body awaits: the canonical sentence is on
        // screen from the first frame, and a personalized one replaces it later or not at all.
        //
        // Keyed on the assignment so paging between two cards asks for each once, and re-keyed by
        // the canonical text so a library edit invalidates rather than reuses.
        .task(id: canonicalPrompt) {
            await personalization.request(
                assignmentId: assignment.id,
                canonical: canonicalPrompt,
                subject: promptSubject,
                ageMonths: childAgeMonths
            )
        }
    }

    // MARK: Zones

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            glyphTile

            KindBadge(kind: assignment.promptKind.badgeText, tint: tint)

            if let expiry = expiryText {
                ExpiryChip(text: expiry)
            }

            Spacer(minLength: 0)

            if isDone {
                // Ring and check are one control: the ring fills as bytes land and closes into the
                // check drawing itself, so upload and completion read as one motion.
                UploadRing(
                    fraction: item.mediaProgress?.fraction ?? 1,
                    remaining: item.mediaProgress?.remaining ?? 0,
                    isComplete: item.mediaProgress?.isFinished ?? true,
                    diameter: 26
                )
            }
        }
    }

    /// Filled, unlike the washed tile on a compact row. This is the card that is asking.
    @ScaledMetric(relativeTo: .title3) private var tileSize: CGFloat = 34
    /// Scaled alongside the tile. A fixed glyph inside a growing frame becomes a dot.
    @ScaledMetric(relativeTo: .title3) private var glyphSize: CGFloat = 15

    private var glyphTile: some View {
        Image(systemName: assignment.symbolName)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(Color.surface)
            .frame(width: tileSize, height: tileSize)
            .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }

    /// A quiet line naming what this is, and the action beside it.
    ///
    /// `ViewThatFits` rather than a fixed row: at accessibility sizes "All week to finish" beside
    /// a capsule reading "Capture it" does not fit on a 393pt screen, and the button is the half
    /// that must never be clipped.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                footnote
                Spacer(minLength: 8)
                actionButton
            }
            VStack(alignment: .leading, spacing: 10) {
                footnote
                actionButton
            }
        }
    }

    private var footnote: some View {
        Text(assignment.footnoteLabel(asOf: today))
            .typeRole(.metadata)
            .foregroundStyle(Color.inkMuted)
    }

    private var actionButton: some View {
        Button(assignment.completion.actionText, action: onPrimary)
            .buttonStyle(PrimaryButtonStyle(tint: tint, fullWidth: false))
    }

    // MARK: Presentation

    /// Local truth counts. An entry saved offline is done the instant it is saved; whether the
    /// server has heard is a fact about the network, not about the parent's evening.
    private var isDone: Bool { item.isDone }

    private var tint: Color { assignment.tint }

    /// **Done keeps its kind.**
    ///
    /// Previously every done card went sage, which threw away the one thing the colour was carrying
    /// at the moment the card is most satisfying to look at: a completed question stopped being a
    /// question. The tint means mission-or-question; finishing does not change what it was.
    ///
    /// Sage stays for `did_it` specifically, where it is not decoration — it marks the completion
    /// shape that produces no artifact, which is the one the archive is most likely to under-value.
    private var fill: Color {
        if isDone, assignment.completion == .didIt { return .sage }
        return assignment.softTint
    }

    /// A tinted card gets a tinted hairline.
    private var border: Color {
        if isDone, assignment.completion == .didIt { return .sageBorder }
        return assignment.tintBorder
    }

    /// "2 days left", within three days of expiry. Nothing counts down before that, and nothing
    /// turns red at any point.
    private var expiryText: String? {
        guard !isDone else { return nil }
        return assignment.expiryLabel(asOf: today)
    }

    private var accessibilityText: String {
        var parts = [assignment.promptKind.badgeText, prompt]
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
    /// The quiet line under a live prompt: "Today's mission", "All week to finish".
    ///
    /// Names the slot rather than counting anything. A card that said "day 4 of 7" would be a
    /// streak counter wearing a different hat.
    func footnoteLabel(asOf today: String) -> String {
        switch slotKind {
        case .weekly: "All week to finish"
        case .monthly: "Any time this month"
        case .letter: "A letter, for later"
        case .question: assignedOn == today ? "Today's question" : "Still open"
        // Both daily missions say the same thing. There is no "second mission" in the copy —
        // see `Slot.displayName`.
        case .mission, .missionB: assignedOn == today ? "Today's mission" : "Still open"
        case .unknown: "Still open"
        }
    }
}

#if DEBUG
#Preview("Prompt card — states") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            SectionLabel("Pending")
            PromptCard(item: TodayPreview.item(.photo), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
            PromptCard(item: TodayPreview.item(.question), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
            PromptCard(item: TodayPreview.item(.didIt), today: TodayPreview.today, onPrimary: {}, onDismiss: {})

            SectionLabel("Expiring soon")
            PromptCard(item: TodayPreview.item(.expiringSoon), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
            PromptCard(item: TodayPreview.item(.expiringTomorrow), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
            PromptCard(item: TodayPreview.item(.expiringToday), today: TodayPreview.today, onPrimary: {}, onDismiss: {})

            SectionLabel("Done")
            PromptCard(item: TodayPreview.item(.photo, done: true, progress: TodayPreview.finished),
                       today: TodayPreview.today, onPrimary: {}, onDismiss: {}, onEdit: {})
            PromptCard(item: TodayPreview.item(.didIt, done: true),
                       today: TodayPreview.today, onPrimary: {}, onDismiss: {}, onEdit: {})

            SectionLabel("Uploading")
            PromptCard(item: TodayPreview.item(.photo, done: true, progress: TodayPreview.uploading),
                       today: TodayPreview.today, onPrimary: {}, onDismiss: {}, onEdit: {})

            SectionLabel("Weekly and monthly")
            PromptCard(item: TodayPreview.item(.weekly), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
            PromptCard(item: TodayPreview.item(.monthly), today: TodayPreview.today, onPrimary: {}, onDismiss: {})

            SectionLabel("Unknown kind — neutral, never blank")
            PromptCard(item: TodayPreview.item(.unknownKind), today: TodayPreview.today, onPrimary: {}, onDismiss: {})

            SectionLabel("Long body")
            PromptCard(item: TodayPreview.item(.longBody), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
}

#Preview("Prompt card — AX XXL") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            PromptCard(item: TodayPreview.item(.photo), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
            PromptCard(item: TodayPreview.item(.longBody), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
            PromptCard(item: TodayPreview.item(.weekly), today: TodayPreview.today, onPrimary: {}, onDismiss: {})
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
