import SwiftUI

/// A slot today's board was **not** served, because this household is on the free tier.
///
/// **A quieter `PromptCard`, not a broken one.** It reuses that card's geometry — radius 20, a 34pt
/// glyph tile at radius 11, 16 of padding, 14 between zones — and differs in four ways, each drawn
/// from the approved design at `docs/App-Views/mobile-app-design-tiers-lock-cta/`:
///
/// - **the fill is treatment C**, `terracottaSoft` at 45% over canvas — see `washedFill`;
/// - the tile is **washed rather than filled**, the treatment `WaitingCard` uses at 30pt;
/// - all three zones are `inkMuted`, so a live card is always the darkest thing on the board;
/// - the kind badge, expiry chip and capsule button are replaced by an **eyebrow** above the body
///   and a **hairline rule with one line under it** below.
///
/// **It says nothing about the prompt it stands in for**, because the server sends nothing about
/// one: `locked[]` is `{slot, kind_hint}` and Lane A has frozen it there. That is right rather than
/// limiting — the copy file's rule 5 is *"Show the shape, never blur the content… Hidden content
/// behind frosted glass is a dark pattern and off-register for this product."*
///
/// **Not dismissible**, and that is a rule rather than an omission: no swipe, no context menu, no ✕.
/// A lock you can dismiss becomes a thing to dismiss every morning — and there is nothing to
/// decline, because this was never offered.
///
/// **The whole card is one button** and it opens membership. No chevron: a chevron promises
/// navigation to content, and there is no content behind this.
struct LockedPromptCard: View {
    let locked: LockedSlot
    let onOpenMembership: () -> Void

    /// The child every string on this card is about. Same environment value `PromptCard` reads, and
    /// for the same reason — see `MembershipCopy`'s note on pronouns.
    @Environment(\.promptSubject) private var promptSubject

    private var slot: Slot { locked.slotKind }

    private var eyebrow: String {
        PromptTokens.render(MembershipCopy.lockedEyebrow(slot), for: promptSubject)
    }

    private var body_: String {
        PromptTokens.render(MembershipCopy.lockedBody(slot), for: promptSubject)
    }

    var body: some View {
        Button(action: onOpenMembership) {
            // Three zones at 14, which is `PromptCard`'s spacing and the only interior gap the
            // design uses on this card.
            VStack(alignment: .leading, spacing: 14) {
                // **The tile and the eyebrow share a row**, which is exactly the slot
                // `PromptCard.header` gives its `KindBadge` — the thing this replaces. The eyebrow
                // is plain rather than a pill: a pill here would hand the locked card the one piece
                // of furniture that says "this is live". Position from the design, styling from
                // that reasoning; they are separate decisions and both are deliberate.
                HStack(alignment: .center, spacing: 10) {
                    glyphTile

                    Text(eyebrow)
                        .typeRole(.label)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }

                Text(body_)
                    .typeRole(.promptBody)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.cardPadding)
            // The wash, then the ground it is composited against. `.background` draws *behind*, so
            // the second call is the lower layer — see `washedFill`.
            .background(washedFill, in: cardShape)
            .background(Color.canvas, in: cardShape)
            .overlay(cardShape.strokeBorder(Color.border, lineWidth: Layout.borderWidth))
            // **The resting shadow, which treatment C keeps** and treatment A would have dropped.
            //
            // Read off `Layout.Shadow` rather than written as numbers, so it cannot drift from the
            // shadow every other card carries — the whole point of C over A is that the locked card
            // sits *beside* live ones, and a shadow that differed by a hair would be the only thing
            // anyone could perceive. The halving is `cardSurface`'s own: SwiftUI's radius is roughly
            // half a designer's blur.
            .shadow(
                color: .ink.opacity(Layout.Shadow.opacity),
                radius: Layout.Shadow.blur / 2,
                x: 0,
                y: Layout.Shadow.y
            )
            // **The tap target is the whole card, including its padding.**
            //
            // Not automatic: a `VStack` of text inside padding hit-tests to the text, leaving a
            // 16pt dead ring where a parent's thumb actually lands. `PromptCard` carries the same
            // line for the same reason.
            .contentShape(cardShape)
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MembershipCopy.lockedAccessibilityLabel(slot, subject: promptSubject))
        .accessibilityHint(MembershipCopy.lockedHint)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
    }

    // MARK: The fill — treatment C

    /// **`terracottaSoft` at 45%, composited over canvas.**
    ///
    /// The design rendered four treatments at card width and **recommended A** — `surface`, border,
    /// no shadow — arguing against this one by name: *"`terracottaSoft` at any opacity is the fill a
    /// **live** mission wears. Washing it makes the locked card look like a live mission rendering
    /// badly."* **The owner chose C anyway**, having read that argument. So: the design recommended
    /// A, the owner chose C, and C is what ships. The objection is recorded in the phase's PR
    /// because it is the strongest thing said against this and it should outlive the decision.
    ///
    /// It resolves to `#FCF4EC` — lighter and pinker than a live mission's flat `#FBEDE2`, so the
    /// two are distinguishable when adjacent, which is the objection answered by measurement.
    /// `inkMuted` on it measures 4.94:1, so all three zones clear AA.
    ///
    /// **Two layers rather than the resolved literal, and that is load-bearing.** A bare
    /// `.opacity(0.45)` composites against whatever is behind the card — inside a `List` row that is
    /// canvas today and is not guaranteed to stay canvas. Stating the ground makes the fill the same
    /// colour wherever this card is put, and keeps it derived from the palette rather than frozen as
    /// a hex that would silently stop matching if `terracottaSoft` were ever retuned.
    private var washedFill: some ShapeStyle {
        Color.terracottaSoft.opacity(0.45)
    }

    // MARK: Zones

    /// Washed, at `PromptCard`'s 34 rather than `WaitingCard`'s 30: this sits among full cards, so
    /// it keeps the full card's proportions and gives up only its weight.
    ///
    /// **Scaled, and both numbers scale together** — a fixed glyph inside a growing frame becomes a
    /// dot, which is the one element that would silently stop answering Dynamic Type.
    @ScaledMetric(relativeTo: .title3) private var tileSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title3) private var glyphSize: CGFloat = 15

    private var glyphTile: some View {
        Image(systemName: locked.kind.symbolName)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: tileSize, height: tileSize)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }

    /// A hairline and one line under it.
    ///
    /// **No glyph.** The design drew that as treatment D and rejected it: *"The kind glyph is
    /// already on the card, in the tile, 34pt. A second mark 13pt below it says nothing the first
    /// one didn't… It also reads as the ring of a disabled control."* This phase's prompt asks for a
    /// glyph here; the approved design refuses one, and the design's reasoning is sound — so there
    /// is a rule instead, which is what the annotation specifies.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(Color.border)
                .frame(height: Layout.borderWidth)

            Text(MembershipCopy.lockedFooter)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Presentation

    /// Colour carries meaning, and the same meaning as everywhere else: terracotta is missions,
    /// photo and video and the bigger slots; periwinkle is questions and voice.
    ///
    /// A letter is periwinkle — it is written, not done — which is the tint `AssignmentResponse`
    /// gives a `letter` prompt, whose completion mode is `text`.
    ///
    /// **An unrecognised hint gets no tint rather than a guessed one**, the contract
    /// `AssignmentResponse.isRecognised` states for a value from a future server release.
    private var tint: Color {
        guard locked.kind.isRecognised else { return .inkMuted }
        return locked.kind == .letter ? .periwinkle : .terracotta
    }
}

#if DEBUG
private let previewChild = PromptSubject(name: "Milo", pronouns: .heHim)

#Preview("Locked card — every slot") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            SectionLabel("Every slot the server can lock")
            LockedPromptCard(locked: LockedSlot(slot: "mission", kindHint: "photo")) {}
            LockedPromptCard(locked: LockedSlot(slot: "mission_b", kindHint: "mission")) {}
            LockedPromptCard(locked: LockedSlot(slot: "weekly", kindHint: "weekly")) {}
            LockedPromptCard(locked: LockedSlot(slot: "monthly", kindHint: "monthly")) {}
            LockedPromptCard(locked: LockedSlot(slot: "letter", kindHint: "letter")) {}

            SectionLabel("A slot newer than this build — neutral, never blank")
            LockedPromptCard(locked: LockedSlot(slot: "seasonal", kindHint: "seasonal")) {}
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .promptSubject(previewChild)
}

/// **The pronoun rule, seen rather than argued about.** The same three cards for three children.
/// The `he/him` column is the owner's copy verbatim; the other two are what neutral-by-default
/// would otherwise have got wrong.
#Preview("Locked card — pronouns") {
    ScrollView {
        VStack(spacing: 20) {
            ForEach(
                [("he/him", PronounSet.heHim), ("she/her", .sheHer), ("unanswered", nil as PronounSet?)],
                id: \.0
            ) { label, set in
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    SectionLabel(label)
                    LockedPromptCard(locked: LockedSlot(slot: "mission", kindHint: "photo")) {}
                    LockedPromptCard(locked: LockedSlot(slot: "letter", kindHint: "letter")) {}
                }
                .promptSubject(PromptSubject(name: "Sam", pronouns: set))
            }
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
}

/// **The worst case, which no artboard draws.** A Saturday that is also the 15th serves both daily
/// missions, the weekly and the letter — four locked cards against one live question. The design's
/// `1e` already warns a single card is ~270pt at AX1; this is that, four times.
#Preview("Locked card — the four-lock Saturday") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            LockedPromptCard(locked: LockedSlot(slot: "mission", kindHint: "photo")) {}
            LockedPromptCard(locked: LockedSlot(slot: "mission_b", kindHint: "mission")) {}
            LockedPromptCard(locked: LockedSlot(slot: "weekly", kindHint: "weekly")) {}
            LockedPromptCard(locked: LockedSlot(slot: "letter", kindHint: "letter")) {}
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .promptSubject(previewChild)
}

/// The two things to look at: the glyph tile must still be a tile rather than a dot, and the footer
/// must not wrap to three lines.
#Preview("Locked card — XXL") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            LockedPromptCard(locked: LockedSlot(slot: "mission", kindHint: "photo")) {}
            LockedPromptCard(locked: LockedSlot(slot: "letter", kindHint: "letter")) {}
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .promptSubject(previewChild)
    .environment(\.dynamicTypeSize, .xxLarge)
}

#Preview("Locked card — AX5") {
    ScrollView {
        VStack(spacing: Layout.cardSpacing) {
            LockedPromptCard(locked: LockedSlot(slot: "mission", kindHint: "photo")) {}
            LockedPromptCard(locked: LockedSlot(slot: "monthly", kindHint: "monthly")) {}
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .promptSubject(previewChild)
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
