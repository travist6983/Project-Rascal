import SwiftUI

/// The child's name at the top of Today, on a capsule with their initial.
///
/// **The initial is the whole treatment, not a fallback.** `GET /children/{id}/today` returns
/// `child` as `id`, `name`, `age_months` and nothing else — there is no avatar key on it, and the
/// avatar bytes are not fetchable anyway (see `docs/blocked.md`: the presign routes do not exist,
/// so `avatar_key` stays null). The design draws a coloured disc with a letter in it and never
/// draws a photograph, which is the one treatment that is honest about what the endpoint serves.
///
/// The chevron appears only when there is somewhere to go. One child and a chevron is a control
/// that lies; `ios/CLAUDE.md` scopes multi-kid switching UI out beyond what `GET /children`
/// already returns, so `onSelect` is nil until that exists.
struct ChildSwitcherPill: View {
    let name: String
    /// Supplied only when more than one child exists. Nil renders a label, not a button.
    var onSelect: (() -> Void)?

    var body: some View {
        Group {
            if let onSelect {
                Button(action: onSelect) { pill }
                    .buttonStyle(TapScaleButtonStyle())
            } else {
                pill
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .accessibilityHint(onSelect == nil ? "" : "Switch child")
    }

    private var pill: some View {
        HStack(spacing: 9) {
            initialDisc

            Text(name)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                // A 24-character name truncates rather than pushing the row's trailing controls
                // off the screen. One line, because this is a label on a pill and not a heading.
                .lineLimit(1)
                .truncationMode(.tail)

            if onSelect != nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSize, weight: .semibold))
                    // `inkMuted`, not `inkFaint`: this chevron is the only thing distinguishing an
                    // interactive pill from a label, and the faint step is 2.2:1 against `surface`.
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, onSelect == nil ? 14 : 12)
        .padding(.vertical, 6)
        .background(Color.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
    }

    /// Scales with Dynamic Type: at accessibility sizes a fixed 30pt disc beside 30pt text reads
    /// as a bullet point rather than an avatar.
    @ScaledMetric(relativeTo: .headline) private var discSize: CGFloat = 30
    @ScaledMetric(relativeTo: .headline) private var chevronSize: CGFloat = 11

    private var initialDisc: some View {
        Text(initial)
            .typeRole(.metadata)
            .fontWeight(.bold)
            .foregroundStyle(Color.surface)
            .frame(width: discSize, height: discSize)
            .background(Color.terracotta, in: Circle())
    }

    /// First letter, uppercased. A name that is entirely emoji or whitespace still has to produce
    /// a disc rather than an empty circle — the archive belongs to a real child either way.
    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

#if DEBUG
#Preview("Child switcher") {
    VStack(alignment: .leading, spacing: 16) {
        SectionLabel("No switcher — one child")
        ChildSwitcherPill(name: "Hendrix")

        SectionLabel("With switcher")
        ChildSwitcherPill(name: "Hendrix", onSelect: {})

        SectionLabel("Long name — 24+ characters")
        ChildSwitcherPill(name: "Wilhelmina Constanza Ortiz", onSelect: {})

        SectionLabel("Long name, constrained width")
        ChildSwitcherPill(name: "Wilhelmina Constanza Ortiz", onSelect: {})
            .frame(maxWidth: 200, alignment: .leading)

        SectionLabel("Single character")
        ChildSwitcherPill(name: "Q")
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.canvas)
}

#Preview("Child switcher — AX XXL") {
    VStack(alignment: .leading, spacing: 16) {
        ChildSwitcherPill(name: "Hendrix", onSelect: {})
        ChildSwitcherPill(name: "Wilhelmina Constanza Ortiz", onSelect: {})
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
