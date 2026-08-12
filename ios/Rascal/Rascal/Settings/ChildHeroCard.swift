import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The child, at the top of Settings.
///
/// **This is the whole argument of the design import.** Settings used to open on a small-caps
/// "ARCHIVE" label above a row that said `Name — Hendrix`; it now opens on Hendrix. The screen is
/// about a person before it is about configuration, and a row in a list is the one shape that
/// cannot say so.
///
/// It replaces the `Name` row rather than sitting above it — tapping the card opens the same
/// `EditChildSheet` that `Birthday` and `Timezone` open, so nothing moved further away and one
/// row left the list.
///
/// **Tinted `terracottaSoft`, not washed.** The import puts a three-stop gradient here, and
/// `Gradients.wash` is the palette's own version of it — but `inkMuted` over that gradient
/// measures 4.22:1 on its middle stop, under AA, and the gradient is reserved for emotional beats
/// besides. `terracottaSoft` is the import's own first stop to the digit, is the tinted fill the
/// app already pairs with the cream hairline on `PromptCard`, and measures 4.69:1. See
/// `docs/settings-v2-inventory.md`, D2.
///
/// The import's three-stat strip — `412 entries · 1,204 photos · 3 sealed` — is **not** here.
/// `ChildResponse` carries no counts, no endpoint reports them, and the local cache is paged and
/// partial by construction, so any number it produced would be a claim about how much of the
/// archive this phone happens to hold. `design-system.md` already settles that rule for the
/// timeline header. See D1.
struct ChildHeroCard: View {
    /// Nil until `GET /children` lands — on a first launch with no network, indefinitely.
    let child: ChildResponse?
    /// The avatar's JPEG bytes, or nil for a child who has none.
    ///
    /// **Nil is not a failure state and gets no treatment of its own.** A child with no avatar, a
    /// fresh install that is offline, and a key whose object has gone all render the initials
    /// disc — which is what this card showed unconditionally before there was anywhere to upload
    /// an avatar to, so the fallback is the previous design rather than a new one.
    var avatar: Data?
    /// Opens the edit sheet. Never called while `child` is nil: the placeholder is not a button,
    /// which is the single condition rather than a second nullable the caller could disagree with.
    let action: () -> Void

    /// The disc scales with the name beside it, or it becomes a dot next to 40pt text at the
    /// accessibility sizes.
    @ScaledMetric(relativeTo: .title) private var diameter: CGFloat = 56

    /// **The padding lives inside the button, not around it.**
    ///
    /// `cardSurface` pads and *then* fills, which puts a 16pt ring of card outside the tap target —
    /// so the top-left of a 90pt card, where a thumb naturally lands on the avatar, would have done
    /// nothing. `SettingsCard` fills and lets its content pad itself, which is why every row on
    /// this screen is tappable to its own edges, and the hero is built the same way.
    var body: some View {
        SettingsCard(fill: .terracottaSoft) {
            if let child {
                Button(action: action) {
                    content(child)
                        .padding(Layout.cardPadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TapScaleButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(child))
                .accessibilityHint("Opens name, birthday, pronouns and timezone")
                .accessibilityAddTraits(.isButton)
            } else {
                placeholder
                    .padding(Layout.cardPadding)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.placeholderText)
            }
        }
    }

    // MARK: Loaded

    private func content(_ child: ChildResponse) -> some View {
        HStack(spacing: 14) {
            disc(initial: Self.initial(of: child.name))

            VStack(alignment: .leading, spacing: 3) {
                Text(child.name)
                    .typeRole(.detailTitle)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.subtitle(for: child))
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The child's face when there is one, their initial when there is not.
    ///
    /// **The ring and the frame live here rather than in either branch**, so the disc is the same
    /// size and the same shape whichever one draws — an avatar that arrives a moment after the
    /// name must not resize or re-ring the circle it lands in.
    ///
    /// `scaledToFill` inside a `Circle` clip even though `AvatarCrop` already centre-cropped to a
    /// square: that is not a second crop, it is the guard against bytes that predate the rule, or
    /// that came back from storage having been written by something else.
    @ViewBuilder
    private func disc(initial: String) -> some View {
        ZStack {
            #if canImport(UIKit)
            if let avatar, let image = UIImage(data: avatar) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                initialDisc(initial)
            }
            #else
            initialDisc(initial)
            #endif
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.canvas.opacity(0.7), lineWidth: 3))
    }

    /// A terracotta disc with the initial reversed out of it. The cream ring that separates it
    /// from the peach behind it is applied by `disc`, so both branches get the same one.
    ///
    /// `canvas` on `terracotta` measures 4.25:1 — under AA for body text, over the 3:1 asked of
    /// large text, which at `.detailTitle` (26pt bold) is what this is. It is also decorative:
    /// the name is spelled out in full immediately to its right and the disc is inside the
    /// combined accessibility element, so nothing here is the only copy of anything.
    private func initialDisc(_ initial: String) -> some View {
        Text(initial)
            .typeRole(.detailTitle)
            .foregroundStyle(Color.canvas)
            .frame(width: diameter, height: diameter)
            .background(Color.terracotta)
    }

    // MARK: Not loaded

    /// One line, and a disc with nothing in it.
    ///
    /// Deliberately says nothing about *why*. This is reached both while the fetch is in flight
    /// and after it has failed offline, and `SettingsScreen`'s notice line is what distinguishes
    /// them — a hero that guessed "Loading…" would be lying in the second case, which on a first
    /// launch with no network is the one that lasts.
    private var placeholder: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.chipPlain)
                .frame(width: diameter, height: diameter)
            Text(Self.placeholderText)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let placeholderText = "Waiting for this archive's details."

    // MARK: Wording

    /// "4 years, 1 month · born 19 June 2022".
    ///
    /// `AgeText.long` and nothing computed here: `age_months` is the server's, worked out from the
    /// birthdate it holds, and a client that recomputes drifts the moment a rounding rule differs.
    static func subtitle(for child: ChildResponse) -> String {
        let age = AgeText.long(child.ageMonths)
        guard let born = longBirthdate(child.birthdate) else { return age }
        return "\(age) · born \(born)"
    }

    /// The full month, unlike the `Birthday` row's medium form — the hero has the width for it and
    /// the import spells it out. Read through the same day-only calendar `EditChildModel` uses, so
    /// a June birthday cannot render as May.
    static func longBirthdate(_ raw: String) -> String? {
        guard let date = EditChildModel.dayFormatter.date(from: raw) else { return nil }
        let display = DateFormatter()
        display.locale = .autoupdatingCurrent
        display.timeZone = .current
        display.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "d MMMM y", options: 0, locale: .autoupdatingCurrent
        ) ?? "d MMMM y"
        return display.string(from: date)
    }

    /// The first character of the name, uppercased.
    ///
    /// Grapheme-wise rather than by `UnicodeScalar`, so a name beginning with an emoji or a
    /// combining pair yields one glyph rather than half of one. Empty for an empty name, which
    /// leaves a plain disc rather than a box.
    static func initial(of name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return ""
        }
        return String(first).uppercased()
    }

    /// Spelled out for VoiceOver, where "4y 1m" reads as noise and the chevron says nothing.
    private func accessibilityLabel(_ child: ChildResponse) -> String {
        var parts = [child.name, AgeText.spoken(child.ageMonths)]
        if let born = Self.longBirthdate(child.birthdate) { parts.append("born \(born)") }
        return parts.joined(separator: ", ")
    }
}
