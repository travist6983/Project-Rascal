import SwiftUI

/// The signed-in person: one editable name, and an email that is not theirs to retype.
struct EditProfileSheet: View {
    @State var model: EditProfileModel
    let onSaved: (UserResponse) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameField
                    emailRow
                    if let notice = model.notice { noticeLine(notice) }
                }
                .padding(Layout.screenMargin)
            }
            .background(Color.canvas)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSaving ? "Saving" : "Save") { Task { await save() } }
                        .foregroundStyle(model.canSave ? Color.terracotta : Color.inkMuted)
                        .disabled(!model.canSave)
                }
            }
            .task { nameFocused = true }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Your name")
            TextField("Your name", text: $model.displayName)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { Task { await save() } }
                .padding(12)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                )

            Text("This is how you're named in the archive.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)

            if let warning = model.lengthWarning {
                Text(warning)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
        }
    }

    /// Read-only, and **nil-safe by construction**. Apple's relay addresses are unreliable and
    /// the column is nullable, so this renders words in both states — never an empty value, and
    /// never a crash.
    private var emailRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Email")
            HStack {
                Text(model.emailDisplay)
                    .typeRole(.body)
                    .foregroundStyle(model.emailIsMissing ? Color.inkMuted : Color.ink)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )

            Text("Comes from how you signed in, so it isn't editable here.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }
    }

    private func noticeLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.inkMuted)
            Text(text)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
    }

    private func save() async {
        guard let updated = await model.save() else { return }
        onSaved(updated)
        dismiss()
    }
}
