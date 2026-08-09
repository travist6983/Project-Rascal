import SwiftUI

/// The timeline workhorse, to the spec in `docs/design-system.md`.
///
/// The rule the layout is built around: **nothing here assumes an entry has media.** A written
/// entry and a did-it entry are complete, legitimate entries, and they render with no thumbnail
/// slot at all — not an empty frame, not a grey square, not a gap where a picture would go. Half
/// the mission library produces no artifact, so this is the common case rather than the edge.
struct EntryCard: View {
    let model: EntryCardModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                text
                if let voice = model.voice { voiceChip(voice) }
                metadata
                // A row of tiles across the card, rather than a single trailing square, once
                // there is more than one picture. An entry holding six photos should look like
                // it holds six photos.
                if model.thumbnails.count > 1 || (model.thumbnails.count == 1 && model.overflow > 0) {
                    thumbnailRow
                }
            }

            // One picture keeps the trailing square the spec asks for, which is what makes a
            // long list scan: the text starts in the same place on every row.
            if model.thumbnails.count == 1, model.overflow == 0, let only = model.thumbnails.first {
                Spacer(minLength: 8)
                MediaThumbnail(
                    mediaId: only.id,
                    kind: only.kind,
                    durationSeconds: only.durationSeconds
                )
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(fill: model.isDidIt ? .sage : .surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Text

    @ViewBuilder
    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = model.title, !title.isEmpty {
                Text(title)
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
            }
            if let preview = model.preview {
                Text(preview)
                    .typeRole(.body)
                    .foregroundStyle(model.title == nil ? Color.ink : Color.inkMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if model.isSealed { sealedLine }
            // A card with neither a title nor a body still has to say what it is. A did-it
            // entry with no note is the archive working as designed, not a blank row.
            if model.title == nil, model.preview == nil, !model.isSealed {
                Text(model.isDidIt ? "We did it" : (model.typeLabel ?? "Entry"))
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
            }
        }
    }

    /// Warm and deliberate, not mysterious. It says what it is and when it opens.
    private var sealedLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 12, weight: .medium))
            Text(model.unlockAtAge.map { "Sealed until \($0)" } ?? "Sealed")
                .typeRole(.metadata)
        }
        .foregroundStyle(Color.terracottaDeep)
    }

    // MARK: Voice

    private func voiceChip(_ voice: EntryCardModel.Voice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                Text(voice.durationSeconds.map(DurationText.clock) ?? "Voice")
                    .typeRole(.metadata)
            }
            .foregroundStyle(Color.periwinkle)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.periwinkleSoft, in: Capsule())

            if let line = voice.openingLine {
                Text(line)
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Media

    private var thumbnailRow: some View {
        HStack(spacing: 8) {
            ForEach(model.thumbnails) { thumbnail in
                MediaThumbnail(
                    mediaId: thumbnail.id,
                    kind: thumbnail.kind,
                    durationSeconds: thumbnail.durationSeconds
                )
            }
            if model.overflow > 0 { OverflowTile(count: model.overflow) }
            Spacer(minLength: 0)
        }
    }

    // MARK: Metadata

    private var metadata: some View {
        HStack(spacing: 6) {
            if let months = model.ageMonths {
                Chip(text: AgeText.chip(months), background: .border)
            }
            if let label = model.typeLabel {
                Chip(text: label, foreground: typeTint.ink, background: typeTint.soft)
            }
            // Two tags. A third would push the row past the card on a narrow phone, and a
            // truncated chip reads as a rendering fault rather than as a tag.
            ForEach(model.tags.prefix(2), id: \.self) { tag in
                Chip(text: tag, background: .border)
            }
            if model.isAwaitingSync {
                // A fact about the network, never an error and never a loss.
                Chip(text: "Saving", foreground: .inkMuted, background: .surface, bordered: true)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    /// Colour carries meaning: terracotta for photo and video, periwinkle for voice, and a
    /// neutral for the rest. On a sage did-it card the chip goes to surface, because sage on
    /// sage is not a chip.
    private var typeTint: (soft: Color, ink: Color) {
        switch model.type {
        case .photo, .video: (.terracottaSoft, .terracottaDeep)
        case .audio: (.periwinkleSoft, .periwinkle)
        case .didIt: (.surface, .inkMuted)
        default: (.border, .inkMuted)
        }
    }

    // MARK: Accessibility

    /// One sentence, in the order someone would say it. `AgeText.spoken` rather than the chip's
    /// "5y 2m", which VoiceOver reads as noise.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let title = model.title, !title.isEmpty { parts.append(title) }
        if let preview = model.preview { parts.append(preview) }
        if model.isSealed {
            parts.append(model.unlockAtAge.map { "Sealed until age \($0)" } ?? "Sealed")
        }
        if let label = model.typeLabel { parts.append(label) }
        if let voice = model.voice, let seconds = voice.durationSeconds {
            parts.append(DurationText.spoken(seconds))
        }
        let pictures = model.thumbnails.count + model.overflow
        if pictures > 1 { parts.append("\(pictures) pictures") }
        if let months = model.ageMonths { parts.append(AgeText.spoken(months)) }
        parts.append(DayHeaderText.full(model.occurredAt))
        return parts.joined(separator: ". ")
    }
}
