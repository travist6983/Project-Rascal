import SwiftData
import SwiftUI

/// Name, birthday, and the timezone the schedule runs in.
struct EditChildSheet: View {
    @State var model: EditChildModel
    /// Handed the updated child so Settings can show the new values without refetching.
    let onSaved: (ChildUpdateResponse) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingTimeZones = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameField
                    birthdayField
                    timezoneField
                    if let notice = model.notice { noticeLine(notice) }
                }
                .padding(Layout.screenMargin)
            }
            .background(Color.canvas)
            .navigationTitle("Archive")
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
            .sheet(isPresented: $showingTimeZones) {
                TimeZonePickerSheet(selection: $model.timezone)
            }
        }
    }

    // MARK: Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Name")
            TextField("Their name", text: $model.name)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .padding(12)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                )
        }
    }

    private var birthdayField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Birthday")
            DatePicker(
                "Birthday",
                selection: $model.birthdate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(.terracotta)
            // The picker's numerals inherit the ambient foreground; `ink` is the palette's
            // reading colour and the only one that clears contrast on cream.
            .foregroundStyle(Color.ink)
            .environment(\.colorScheme, .light)

            // Stated only when the birthdate actually moved. The correction is a separate,
            // deliberate action — this line says so plainly rather than warning about it.
            if model.birthdateChanged {
                Text("Ages already saved on your entries stay as they are. You can correct them under Your data.")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var timezoneField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Timezone")
            Button {
                showingTimeZones = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TimeZoneCatalog.city(model.timezone))
                            .typeRole(.body)
                            .foregroundStyle(Color.ink)
                        Text(model.timezone)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                    }
                    Spacer(minLength: 8)
                    Text(TimeZoneCatalog.offsetLabel(model.timezone))
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.inkMuted)
                }
                .padding(12)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(TapScaleButtonStyle())

            // One quiet line, not a warning box. This is the value the server's scheduler uses
            // to decide when a new day starts, and a parent changing it deserves to know that
            // without being alarmed by it.
            Text("New prompts arrive in the morning in this timezone.")
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

    /// On success the sheet closes. On failure it stays open with the input untouched and the
    /// server's own message under it.
    private func save() async {
        guard let updated = await model.save() else { return }
        onSaved(updated)
        dismiss()
    }
}

/// Every zone `zoneinfo` knows, searchable, defaulting the search to where this phone is.
struct TimeZonePickerSheet: View {
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(TimeZoneCatalog.matching(query), id: \.self) { identifier in
                    Button {
                        selection = identifier
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TimeZoneCatalog.city(identifier))
                                    .typeRole(.body)
                                    .foregroundStyle(Color.ink)
                                if let region = TimeZoneCatalog.region(identifier) {
                                    Text(region)
                                        .typeRole(.metadata)
                                        .foregroundStyle(Color.inkMuted)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(TimeZoneCatalog.offsetLabel(identifier))
                                .typeRole(.metadata)
                                .foregroundStyle(Color.inkMuted)
                            if identifier == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.terracotta)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Color.surface)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .searchable(text: $query, prompt: "Search timezones")
            .navigationTitle("Timezone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.inkMuted)
                }
            }
        }
        .task {
            // Seeded with this phone's zone, which is usually the answer and never the
            // assumption — the field it sets is where the *child* lives.
            if query.isEmpty, selection == TimeZoneCatalog.deviceZone {
                query = TimeZoneCatalog.city(TimeZoneCatalog.deviceZone)
            }
        }
    }
}
