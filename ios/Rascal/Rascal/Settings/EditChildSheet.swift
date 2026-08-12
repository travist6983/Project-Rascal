import SwiftData
import SwiftUI

/// Name, birthday, and the timezone the schedule runs in.
struct EditChildSheet: View {
    @State var model: EditChildModel
    /// Handed the updated child so Settings can show the new values without refetching.
    let onSaved: (ChildUpdateResponse) -> Void

    init(model: EditChildModel, onSaved: @escaping (ChildUpdateResponse) -> Void) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
        // Written by hand for one property, the same way `RootView` does: the correction needs
        // the child and the client, and a `@State` default cannot see either.
        _recompute = State(initialValue: model.makeRecompute())
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var showingTimeZones = false
    @FocusState private var nameFocused: Bool
    /// The correction, run after a successful save when the box is ticked. Built from the model
    /// because that is the only type holding both the child id and the client.
    @State private var recompute: RecomputeAgesModel
    /// The `PATCH` landed. Only ever true while the sheet is still open to report the *second*
    /// outcome — see `save()` — and it is what turns Cancel into Done.
    @State private var hasSaved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameField
                    birthdayField
                    pronounsField
                    timezoneField
                    if let notice = model.notice { noticeLine(notice) }
                }
                .padding(Layout.screenMargin)
            }
            .background(Color.canvas)
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // **"Cancel" disappears once the save has landed.** The sheet now stays open
                // after a successful save when the recompute was asked for, so that
                // `entries_updated` can be read — and leaving a button called Cancel on a screen
                // whose changes are already on the server tells the parent the opposite of what
                // happened. After a save the only exit is Done, and it is the confirming action.
                if !hasSaved {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.foregroundStyle(Color.inkMuted)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if hasSaved {
                        // **Never disabled, not even while the recompute is in flight.** Cancel
                        // is already gone by this point, so disabling this too would leave a
                        // window with no way out of the sheet at all. The count is an offer, not
                        // a thing the parent is held here to watch — and the request completes
                        // server-side whether or not they stay for it.
                        Button("Done") { dismiss() }
                            .foregroundStyle(Color.terracotta)
                    } else {
                        Button(model.isSaving ? "Saving" : "Save") { Task { await save() } }
                            .foregroundStyle(model.canSave ? Color.terracotta : Color.inkMuted)
                            .disabled(!model.canSave)
                    }
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

            // **Offered only while the birthdate is actually different**, and unchecked until
            // somebody ticks it. This replaced a standalone `Corrections` card on the main
            // Settings screen: the reasoning that put it there — irreversible actions get their
            // own whitespace and are never adjacent to an ordinary edit row — still holds, but a
            // correction to a birthday belongs beside the birthday it corrects, where the parent
            // already is at the moment the need arises.
            if model.birthdateChanged {
                recomputeCheckbox
            }
        }
    }

    /// The same three choices onboarding offers, in the same order, sending the same strings.
    ///
    /// **Tapping the chosen row clears it**, which is the only way back to unanswered and is a
    /// state the column genuinely holds. There is no "Prefer not to say" row: that would be a
    /// fourth value the CHECK constraint does not accept, and it would render as an answer in a
    /// place the design says renders as nothing.
    private var pronounsField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Pronouns")
            VStack(spacing: 8) {
                ForEach(PronounSet.allCases, id: \.self) { set in
                    pronounRow(set)
                }
            }

            Text("Prompts will use them.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }
    }

    private func pronounRow(_ set: PronounSet) -> some View {
        let selected = model.pronouns == set
        return Button {
            model.pronouns = selected ? nil : set
        } label: {
            HStack(spacing: 10) {
                // The label is the wire value, so the row shows exactly what gets stored.
                Text(set.label)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.terracotta)
                }
            }
            .padding(12)
            .background(
                Color.surface,
                in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                    .strokeBorder(
                        selected ? Color.terracotta : Color.border,
                        lineWidth: Layout.borderWidth
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        // The checkmark is not the only carrier of the state — VoiceOver and Switch Control read
        // the trait, and colour alone never means anything in this app.
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(selected ? "Chosen. Tap to clear." : "")
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

    /// The checkbox, and the explanation that was already good.
    ///
    /// A `Toggle` with `.checkbox`-shaped styling rather than a switch: a switch reads as a
    /// standing preference, and this is a one-off instruction attached to this save.
    private var recomputeCheckbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.recomputeAges) {
                Text("Also update the age saved on every entry.")
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(CheckboxToggleStyle())

            Text("Ages are saved with each entry as it's written, so fixing a birthday doesn't change them on its own.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            // The second outcome, reported separately from the first. See `save()`.
            switch recompute.state {
            case .idle:
                EmptyView()
            case .running:
                Text("Updating ages…")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            case .done(let updated, let birthdate):
                Text(RecomputeAgesModel.summary(updated: updated, birthdate: birthdate))
                    .typeRole(.metadata)
                    .foregroundStyle(Color.sageInk)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                // **The birthday is already saved and stays saved.** Said out loud, because the
                // valuable half of this landed and a bare failure line would read as though it
                // had not.
                //
                // "Try again" is here because without it the correction is unreachable from this
                // state: the birthdate now matches the server, so `canSave` is false and Save
                // cannot run it a second time. A parent would have to change the date to
                // something else and back to get another attempt.
                VStack(alignment: .leading, spacing: 8) {
                    Text("The birthday is saved. The ages weren't updated — \(message)")
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") {
                        Task { await recompute.run(context: context) }
                    }
                    .typeRole(.metadata)
                    .foregroundStyle(Color.terracotta)
                    .disabled(recompute.isRunning)
                }
            }
        }
    }

    /// **`PATCH /children/{id}` first, and the recompute only if that succeeded and the box is
    /// ticked.** They are two outcomes, and the parent is told both.
    ///
    /// A recompute failure must not roll back the birthdate: the correction is the valuable half
    /// and it has already landed on the server by the time this runs. So the sheet stays open on
    /// a failure with the birthday reported as saved, rather than dismissing on a half-success or
    /// — far worse — undoing the edit that worked.
    private func save() async {
        // Read before the write, because `model.recomputeAges` is derived from `birthdateChanged`
        // and the intent must not depend on anything the save does afterwards.
        let wantsRecompute = model.recomputeAges
        guard let updated = await model.save() else { return }
        onSaved(updated)

        guard wantsRecompute else {
            dismiss()
            return
        }

        // Held open so `entries_updated` can be read. That number is the confirmation that the
        // thing happened, and dismissing over it would spend the write and show nothing for it.
        //
        // Set **before** the recompute rather than after, so the toolbar stops offering Cancel
        // the instant the birthdate is on the server — including for the seconds the recompute
        // is in flight, which is exactly when a parent might reach for a way out.
        hasSaved = true
        await recompute.run(context: context)
    }
}

/// A checkbox, in the app's own shapes.
///
/// Not a `Switch`: a switch reads as a standing preference that persists, and this is a one-off
/// instruction attached to a single save. Not a bare `Image` either — a `ToggleStyle` keeps the
/// VoiceOver traits, the Switch Control behaviour and the Dynamic Type growth that a hand-built
/// `HStack` of a glyph and a label would silently drop.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(configuration.isOn ? Color.terracotta : Color.inkFaint)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
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
            // Seeded with this phone's city, which is usually the answer — a parent setting
            // this up is normally setting it to where they are.
            //
            // Previously conditioned on the selection *already* matching the device, which made
            // it a no-op in the one case worth seeding for. It is only a starting point: the
            // field it sets is where the *child* lives, and clearing the search shows every
            // zone.
            if query.isEmpty {
                query = TimeZoneCatalog.city(TimeZoneCatalog.deviceZone)
            }
        }
    }
}
