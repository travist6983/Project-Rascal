import SwiftUI

/// The list behind the child pill's chevron.
///
/// **A sheet with a card, not a `Menu` and not a `.confirmationDialog`.** Every other choice in
/// this app that is worth a title and a row per option is presented this way — `AddToArchiveSheet`
/// is the one to compare against, and this borrows its measured-height detent for the same reason:
/// two or three rows are far under half a screen, and `.medium` would open a gulf of empty cream
/// under them. A `Menu` was the other candidate and is wrong here: it renders in the system's
/// vocabulary rather than this one, and the child's initial disc is the whole visual identity of
/// the pill it drops out of.
///
/// **It never offers "add a child".** `POST /children` is reachable only from the six-step setup
/// flow, behind a state the gate assigns only when the account has no children at all. Making it
/// reachable from here is its own phase — this sheet lists what the account already has.
struct ChildSwitcherSheet: View {
    let children: [ChildResponse]
    /// Who is on screen now, so the list can say so. Optional because the sheet is a dumb view and
    /// the caller's state is the authority on what "current" means.
    let selected: UUID?
    /// Re-read the account when the sheet opens, so a child added on another device is here.
    let onRefresh: () async -> Void
    let onSelect: (ChildResponse) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Seeded near the real height for the common case — two children — so the first frame is
    /// within a few points of the measurement that replaces it. `AddToArchiveSheet` explains the
    /// reasoning at length; the number differs because the content does.
    @State private var contentHeight: CGFloat = 260

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.canvas)
        .presentationDragIndicator(.visible)
        .presentationDetents([.height(contentHeight), .large])
        // Best effort and unawaited by the rows: the list already on screen is the one this
        // device resolved at launch, and a parent with no connection can still switch between
        // the children it knows about.
        .task { await onRefresh() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Whose archive?")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .padding(.bottom, 14)

            VStack(spacing: 8) {
                ForEach(children) { child in
                    row(for: child)
                }
            }
        }
        .padding(20)
    }

    private func row(for child: ChildResponse) -> some View {
        Button {
            // **Dismiss first, then act.** The same ordering `AddToArchiveChoice` exists to
            // enforce: selecting replaces the whole view tree above this sheet, and doing that
            // while the sheet is still presented tears down its own presenter mid-animation.
            dismiss()
            onSelect(child)
        } label: {
            HStack(spacing: 12) {
                initialDisc(for: child.name)

                Text(child.name)
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if child.id == selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: checkSize, weight: .semibold))
                        .foregroundStyle(Color.terracotta)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(child.name)
        // The checkmark is colour and a glyph; without this the current child is indistinguishable
        // from the others to VoiceOver.
        .accessibilityAddTraits(child.id == selected ? [.isSelected, .isButton] : .isButton)
    }

    /// The pill's disc, at the pill's size, because this list drops out of the pill and a
    /// different-looking disc would read as a different kind of thing.
    private func initialDisc(for name: String) -> some View {
        Text(initial(of: name))
            .typeRole(.metadata)
            .fontWeight(.bold)
            .foregroundStyle(Color.surface)
            .frame(width: discSize, height: discSize)
            .background(Color.terracotta, in: Circle())
    }

    private func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    @ScaledMetric(relativeTo: .headline) private var discSize: CGFloat = 30
    @ScaledMetric(relativeTo: .headline) private var checkSize: CGFloat = 13
}

#if DEBUG
private func previewChild(_ name: String, _ id: UUID = UUID()) -> ChildResponse {
    ChildResponse(
        id: id,
        name: name,
        birthdate: "2022-06-14",
        pronouns: nil,
        avatarKey: nil,
        familyTimezone: "America/Detroit",
        ageMonths: 49,
        role: "parent"
    )
}

#Preview("Child switcher sheet") {
    let first = previewChild("Hendrix")
    return ChildSwitcherSheet(
        children: [first, previewChild("Wilhelmina Constanza Ortiz")],
        selected: first.id,
        onRefresh: {},
        onSelect: { _ in }
    )
}

#Preview("Three children") {
    let first = previewChild("Q")
    return ChildSwitcherSheet(
        children: [first, previewChild("Hendrix"), previewChild("Ada")],
        selected: first.id,
        onRefresh: {},
        onSelect: { _ in }
    )
}

#Preview("Child switcher sheet — AX XXL") {
    let first = previewChild("Hendrix")
    return ChildSwitcherSheet(
        children: [first, previewChild("Wilhelmina Constanza Ortiz")],
        selected: first.id,
        onRefresh: {},
        onSelect: { _ in }
    )
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
