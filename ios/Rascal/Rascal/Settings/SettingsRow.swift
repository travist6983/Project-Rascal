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
    /// `surface` for every card that holds rows. `ChildHeroCard` is the one that is tinted, and it
    /// keeps the cream `border` — `docs/design-system.md` asks a tinted card for a tinted hairline,
    /// and the hairline the palette names for a terracotta fill *is* `border`. See
    /// `AssignmentPresentation.tintBorder`, which resolves the same way for the same reason.
    var fill: Color = .surface
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
        .background(fill)
        // Clipped rather than merely backgrounded, so a child may carry a fill of its own and
        // still take the card's corners. `SettingsCardHeader` is the reason: the sync card's
        // summary is washed `terracottaSoft` to the card's edge, and without this its two top
        // corners square off and overhang the hairline.
        .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
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

/// A section label with a rule running out from it to the trailing edge.
///
/// The design import's one structural addition to this screen's vocabulary. The rule is not
/// decoration: with nine blocks stacked on one scroll, a bare small-caps label is easy to read as
/// belonging to the card *above* it. A line drawn from the label to the edge closes the group it
/// opens.
///
/// `SectionLabel` is reused rather than restyled — it is shared with Timeline, Today and Moments,
/// and `docs/design-system.md` settles section headers as `inkMuted`. The import sets them
/// `inkFaint`, which measures 2.13:1 on the canvas and is not a contrast this app puts words at.
struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 9) {
            SectionLabel(title)
            Rectangle()
                .fill(Color.border)
                .frame(height: Layout.borderWidth)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 2)
    }
}

/// The head of a card that reports before it lists — the sync card's summary.
///
/// Washed `terracottaSoft` while something is outstanding and plain `surface` when nothing is,
/// which is the whole of its state. **The wash is not an alarm.** A photo that has not uploaded is
/// a fact about the network; the tint says "this is live" in the same colour the app uses for
/// every other thing in progress, and there is no red here or anywhere on this screen.
///
/// The import draws a progress bar in this header at a fixed 64%. It is not built: Settings knows
/// how many items are outstanding and has nothing to divide them by — the size of the archive is a
/// server answer this client never receives. See `docs/settings-v2-inventory.md`, D4.
struct SettingsCardHeader: View {
    let eyebrow: String
    /// The trailing count. Absent when there is nothing to count.
    var counter: String?
    let headline: String
    var detail: String?
    /// Something is happening. Tints the wash and lights the dot.
    var isActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                if isActive {
                    Circle()
                        .fill(Color.terracotta)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                // Styled like `SectionLabel` but written out, deliberately without its
                // `.isHeader` trait: this eyebrow is folded into a combined element below, and a
                // card's summary sentence has no business appearing in VoiceOver's heading rotor
                // alongside the actual section names.
                Text(eyebrow)
                    .typeRole(.label)
                    .foregroundStyle(Color.inkMuted)
                Spacer(minLength: 8)
                if let counter {
                    Text(counter)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            .padding(.bottom, 5)

            Text(headline)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let detail {
                Text(detail)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.cardPadding)
        .background(isActive ? Color.terracottaSoft : Color.surface)
        .accessibilityElement(children: .combine)
        // The counter is left out on purpose. It is the same number the headline already spells
        // out in words — "3 left" after "3 files still to upload" is VoiceOver reading the count
        // twice, which is noise at the one moment a parent is listening carefully.
        .accessibilityLabel(
            [eyebrow, headline, detail].compactMap { $0 }.joined(separator: ". ")
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
///
/// **A row value is `inkMuted`, always.** There was a `valueIsMuted` flag here whose two branches
/// were both `inkMuted`, so it had never once changed a pixel — and both call sites passed it. The
/// design import settles the question rather than reviving the flag: every trailing value in it is
/// `#6E6A63`, and the two toned variants its own row helper supports are never once invoked. The
/// distinction the flag was reaching for is carried by the words — "Not set" — not by the colour.
struct SettingsRow: View {
    let label: String
    var value: String?
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
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // `inkMuted`, not the import's `#C4BAAE`. That measures 1.88:1 on `surface` and
                // `inkFaint` measures 2.19:1 — both under the 3:1 a non-text control is asked for.
                // The chevron carries nothing VoiceOver needs, but taking a control *down* to 2:1
                // to match a mockup is the mistake this phase was told not to repeat.
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
///
/// **The label is `terracottaDeep`, not `terracotta`, and that is a WCAG fix rather than a
/// preference.** `terracotta` `#C05A2B` on `surface` `#FFFDF9` measures **4.36:1**, and this label
/// is `.typeRole(.body)` — 16pt regular, which is *not* WCAG large text — so it needed 4.5:1 and
/// missed it. `terracottaDeep` `#9A431E` measures **6.47:1** on the same ground.
///
/// **Chosen over `ink` and `inkMuted` by the owner on Aug 22, 2026**, both of which also pass:
/// `ink` would make this row byte-identical to `SettingsValueRow` and cost the vocabulary the one
/// signal that says *a thing you do*, and `inkMuted` would render an action quieter than the label
/// above it. `terracottaDeep` is an existing token — `Palette.swift:16`, already carried by the
/// post-trial notice's action — so nothing was invented to fix this.
///
/// **Six other sites had the identical failure** and were corrected with it in phase 112:
/// `SyncPullSection` ×2, `SettingsScreen` ×2, `NotificationSettingsSection` and `GuardiansSection`.
/// The phase's own brief described this as *"every action row"*; it was every action row **and**
/// six standalone body-size terracotta labels, found by sweeping `.typeRole(.body)` against the
/// palette rather than by reading the component list.
///
/// Prior measurements recorded elsewhere are of **different** cases and none of them is this one:
/// `design-system.md:298` is 4.25:1 at 13pt, and `design-conformance-110.md` §8 is 4.36:1 at 17pt
/// semibold — which is large text, and therefore passes at the 3:1 bar this one cannot use.
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
                        .foregroundStyle(isEnabled ? Color.terracottaDeep : Color.inkMuted)
                    if let detail {
                        Text(detail)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isBusy { ProgressView().tint(.terracottaDeep) }
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
