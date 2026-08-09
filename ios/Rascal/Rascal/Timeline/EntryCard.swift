import SwiftUI

/// The timeline workhorse, rebuilt in v3 **around the prompt**.
///
/// The card reads top to bottom in the order the moment happened: what was asked, then what
/// came back. Six zones, stacked — mosaic, voice band, quoted prompt, title, body, chips — and
/// **every one of them drops out when it is empty.** No reserved space, no placeholder frame,
/// no gap where a picture would go. Half the mission library produces no artifact at all, so a
/// card with nothing but a prompt and a title is the common case rather than the degenerate one,
/// and it has to look deliberate.
///
/// Height therefore follows content, and that variation is the only rhythm the list needs. It is
/// also why the overflow count is printed on the fourth tile rather than taking a fifth: nine
/// photos and four photos should not produce two different card heights.
struct EntryCard: View {
    let model: EntryCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.thumbnails.isEmpty {
                MediaMosaic(tiles: model.thumbnails, overflow: model.overflow)
                    .padding(.bottom, 13)
            }
            if let voice = model.voice {
                EntryAudioRow(durationSeconds: voice.durationSeconds)
                    .padding(.bottom, 13)
            }
            if let prompt = model.prompt {
                PromptQuote(text: prompt, rule: ruleColor)
                    .padding(.bottom, 9)
            }
            titleRow.padding(.bottom, 5)
            bodyText
            if hasChips { chips.padding(.top, 12) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSkin(isDidIt: model.isDidIt, isSealed: model.isSealed))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Title

    /// The title, with the one glyph that says what kind of completion this was.
    ///
    /// Only two kinds get a glyph, and both earn it by being invisible otherwise: a did-it entry
    /// has no artifact to look at, and a sealed letter has content the card is deliberately not
    /// showing. Everything else is announced by the thing above it.
    private var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.isDidIt {
                CompletionCheck(isComplete: true, diameter: 19, tint: .sageInk, check: .sage)
                    .padding(.top, 2)
            } else if model.isSealed {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.terracotta)
                    .frame(width: 17, height: 19)
                    .padding(.top, 2)
            }
            Text(titleText)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// A card with no title still has to say what it is. A did-it entry with no note is the
    /// archive working as designed, not a blank row.
    private var titleText: String {
        if let title = model.title, !title.isEmpty { return title }
        if model.isSealed { return "A letter" }
        if model.isDidIt { return "We did it" }
        return model.typeLabel ?? "Entry"
    }

    // MARK: Body

    @ViewBuilder
    private var bodyText: some View {
        if let line = model.bodyLine {
            Text(line.text)
                .typeRole(.body)
                .italic(line.isQuote)
                .foregroundStyle(Color.inkMuted)
                .lineLimit(model.bodyLineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isSealed {
            // The sealed card carries no body at all — `EntryCardModel` never reads one, so
            // there is nothing here to blur or to leak. What it says instead is when it opens,
            // which is the one fact about a sealed letter that is not sealed.
            Text(model.unlockAtAge.map { "Opens at \($0)." } ?? "Sealed.")
                .typeRole(.body)
                .foregroundStyle(Color.sealedInk)
        }
    }

    // MARK: Chips

    /// An entry the server has not typed yet, with no tags and nothing outstanding, has no
    /// chips — and then it has no chip row either, rather than 12pt of held-open space.
    private var hasChips: Bool {
        model.typeLabel != nil || !model.tags.isEmpty || model.isAwaitingSync
    }

    /// The kind leads, tinted; tags follow, neutral.
    ///
    /// **No age chip.** In v3 the age moved to the day header, where it is stated once for the
    /// whole group instead of repeated on every card under the same date.
    private var chips: some View {
        HStack(spacing: 6) {
            if let label = model.typeLabel {
                Chip(
                    text: label,
                    foreground: chipTint.ink,
                    background: chipTint.soft,
                    emphasis: true
                )
            }
            // Two tags. A third pushes the row past the card on a narrow phone, and a truncated
            // chip reads as a rendering fault rather than as a tag.
            ForEach(model.tags.prefix(2), id: \.self) { tag in
                Chip(text: tag, background: .chipPlain, emphasis: true)
            }
            if model.isAwaitingSync {
                // A fact about the network, never an error and never a loss.
                Chip(text: "Saving", background: .surface, bordered: true, emphasis: true)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    // MARK: Tints
    //
    // Colour carries meaning: terracotta is missions and photo/video, periwinkle is questions,
    // voice and writing, sage is did-it. A question card tinted terracotta "because it's the
    // brand colour" is a defect, not a style choice.

    private var ruleColor: Color {
        switch model.tint {
        case .terracotta: .ruleTerracotta
        case .periwinkle: .rulePeriwinkle
        case .sage: .ruleSage
        }
    }

    /// On a sage card the kind chip goes sage-on-sage-soft, a step darker than the card, because
    /// the surface tint it would otherwise wear is invisible there.
    private var chipTint: (soft: Color, ink: Color) {
        switch model.tint {
        case .terracotta: (.terracottaSoft, .terracottaDeep)
        case .periwinkle: (.periwinkleSoft, .periwinkle)
        case .sage: (.sageSoft, .sageInk)
        }
    }

    // MARK: Accessibility

    /// One sentence, in the order someone would say it — and it leads with the prompt, because
    /// that is what the card now leads with. `AgeText.spoken` rather than the header's "4y 2m",
    /// which VoiceOver reads as noise.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let prompt = model.prompt { parts.append("Prompt: \(prompt)") }
        parts.append(titleText)
        if let line = model.bodyLine { parts.append(line.text) }
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

/// The originating prompt, quoted above the entry that answered it.
///
/// A rule and an indent rather than a filled block: on a card the prompt introduces the entry,
/// it does not compete with it. Italic because the words are somebody else's — the archive
/// asked, and everything below this line is the answer.
///
/// Two lines, clamped. The prompts in the library are written to land in one or two.
struct PromptQuote: View {
    let text: String
    let rule: Color

    var body: some View {
        Text(text)
            .typeRole(.quote)
            .italic()
            .foregroundStyle(Color.inkMuted)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 11)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(rule)
                    .frame(width: 2)
            }
    }
}

/// Fill and hairline for the three card states, kept in one place so they cannot drift apart.
private struct CardSkin: ViewModifier {
    let isDidIt: Bool
    let isSealed: Bool

    func body(content: Content) -> some View {
        if isSealed {
            content.cardSurface(wash: Gradients.wash, border: .sealedBorder)
        } else if isDidIt {
            content.cardSurface(fill: .sage, border: .sageBorder)
        } else {
            content.cardSurface(fill: .surface, border: .border)
        }
    }
}
