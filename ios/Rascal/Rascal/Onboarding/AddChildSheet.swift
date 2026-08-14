import SwiftUI

/// Adding a sibling, from a signed-in session.
///
/// **Not `ChildSetupFlow`, and the difference is one step.** Setup is six screens ending in the
/// notification soft-ask, and a parent adding a second child has already answered that for the
/// account — `ios/CLAUDE.md` puts re-prompting out of scope by any mechanism, so reusing the flow
/// would either ask again or need a branch through every step to skip the last one. This collects
/// the four things `POST /children` requires, on one screen, and stops.
///
/// **Avatar is not here either.** Setup offers one because that is the moment a parent is already
/// choosing a photo; here it would be a fifth field on a form whose job is to get a child created.
/// `EditChildSheet` sets one afterwards, which is where the existing child's is set too.
struct AddChildSheet: View {
    /// The current child's zone, when there is one. A sibling almost always lives in the same
    /// house, and the household that has moved is the one a parent will notice and correct.
    let familyTimezone: String?
    let onAdd: (String, String, String, PronounSet?) async -> Bool
    /// Set by the session when a create fails, so this sheet does not keep its own copy of a
    /// message the session owns.
    let notice: String?
    let isWorking: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var birthdate = Date()
    @State private var pronouns: PronounSet?
    @State private var timezone: String
    @State private var showingTimeZones = false

    init(
        familyTimezone: String?,
        notice: String?,
        isWorking: Bool,
        onAdd: @escaping (String, String, String, PronounSet?) async -> Bool
    ) {
        self.familyTimezone = familyTimezone
        self.notice = notice
        self.isWorking = isWorking
        self.onAdd = onAdd
        _timezone = State(initialValue: familyTimezone ?? TimeZoneCatalog.deviceZone)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same bar setup holds: a name and a birthdate, and the server decides the rest.
    private var canSave: Bool { !trimmedName.isEmpty && !isWorking }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Their name") {
                        TextField("Their name", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .typeRole(.body)
                            .foregroundStyle(Color.ink)
                    }

                    field("Birthday") {
                        DatePicker(
                            "Birthday",
                            selection: $birthdate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                    }

                    field("Pronouns") {
                        VStack(spacing: 8) {
                            ForEach(PronounSet.allCases, id: \.self) { set in
                                pronounRow(set)
                            }
                        }
                    }

                    field("Timezone") {
                        Button { showingTimeZones = true } label: {
                            HStack {
                                Text(TimeZoneCatalog.city(timezone))
                                    .typeRole(.body)
                                    .foregroundStyle(Color.ink)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.inkMuted)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if let notice {
                        Text(notice)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.terracotta)
                    }
                }
                .padding(20)
            }
            .background(Color.canvas)
            .navigationTitle("Add a child")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingTimeZones) {
                TimeZonePickerSheet(selection: $timezone)
            }
        }
    }

    /// **Dismiss only on success.** A failed create that closed the sheet would take the parent's
    /// typing with it and leave them on Settings with a message about a child that does not exist.
    private func save() async {
        let added = await onAdd(
            trimmedName,
            EditChildModel.dayFormatter.string(from: birthdate),
            timezone,
            pronouns
        )
        if added { dismiss() }
    }

    private func pronounRow(_ set: PronounSet) -> some View {
        Button {
            // Tapping the chosen answer clears it. An unanswered pronoun is a finished setup and
            // renders the they/them column, so there has to be a way back to it — the same rule
            // `EditChildSheet` follows with its explicit-null clear.
            pronouns = (pronouns == set) ? nil : set
        } label: {
            HStack {
                Text(set.label)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                if pronouns == set {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.terracotta)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(pronouns == set ? [.isSelected, .isButton] : .isButton)
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(label)
            content()
        }
    }
}

#if DEBUG
#Preview("Add a child") {
    AddChildSheet(
        familyTimezone: "America/Detroit",
        notice: nil,
        isWorking: false,
        onAdd: { _, _, _, _ in true }
    )
}

#Preview("Add a child — the create was refused") {
    AddChildSheet(
        familyTimezone: "America/Detroit",
        notice: "That birthdate is in the future.",
        isWorking: false,
        onAdd: { _, _, _, _ in false }
    )
}
#endif
