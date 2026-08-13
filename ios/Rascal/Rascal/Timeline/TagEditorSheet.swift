import SwiftData
import SwiftUI

/// The one place a tag is written. Reached from **Add tag** on Entry Detail.
///
/// **It sends the parent's tags and only the parent's tags.** `PATCH /entries/{id}` replaces the
/// set for each `source` it carries and leaves every source absent from the payload alone, so a
/// write of `user` rows cannot touch what the on-device model extracted — and this sheet never
/// sends a `device_ai` row back. That is also why `Entry` had to start keeping sources: a client
/// that cannot tell the two apart has to send everything as `user` and quietly promotes the
/// model's guesses into the parent's own words, permanently.
///
/// **The server is asked before the cache is changed**, which is the opposite of how an entry is
/// composed and is deliberate. A composed entry holds bytes and sentences that exist nowhere else,
/// so it is written locally first and synced later. A tag is a label on a row the server already
/// has; nothing is lost if it does not land, and there is no retry path that would carry it —
/// `EntrySync` re-sends bodies and dates, not tags. Showing a tag locally that the archive never
/// accepted would be the cache quietly disagreeing with the archive, which is worse than a
/// sentence saying it did not save.
struct TagEditorSheet: View {
    let entryId: UUID
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query private var entries: [Entry]

    /// What the parent is typing. Committed by Return or by the add control.
    @State private var typed = ""
    /// The working set — the parent's own tags, in the order they will be written.
    @State private var working: [String] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var notice: String?
    @FocusState private var fieldFocused: Bool

    init(entryId: UUID, api: APIClient) {
        self.entryId = entryId
        self.api = api
        _entries = Query(filter: #Predicate<Entry> { $0.id == entryId })
    }

    private var entry: Entry? { entries.first }

    /// What the model found, shown but not editable here — deleting the model's guess is a
    /// different decision from managing your own labels, and this sheet does not offer it.
    private var extracted: [String] {
        entry?.tags.filter { $0.source == .deviceAI }.map(\.name) ?? []
    }

    private var changed: Bool { working != (entry?.userTagNames ?? []) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field
                    if !working.isEmpty { yours }
                    if !extracted.isEmpty { found }
                    if let notice {
                        Text(notice)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Layout.screenMargin)
            }
            .background(Color.canvas)
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.inkMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Saving" : "Save") { Task { await save() } }
                        .foregroundStyle(changed && !saving ? Color.terracotta : Color.inkMuted)
                        .disabled(!changed || saving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Once. Re-seeding on every redraw would throw away what the parent has typed the
            // moment anything else on the row changed.
            guard !loaded else { return }
            working = entry?.userTagNames ?? []
            loaded = true
            fieldFocused = true
        }
    }

    // MARK: Pieces

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Add a tag")
            HStack(spacing: 10) {
                TextField("Kitchen table", text: $typed)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .tint(.terracotta)
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(commit)
                if !normalized.isEmpty {
                    Button("Add", action: commit)
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.terracotta)
                }
            }
            .padding(12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            Text("Lowercase, and how you would say it out loud.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }
    }

    private var yours: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("On this entry")
            FlowRow(spacing: 8) {
                ForEach(working, id: \.self) { tag in
                    Button {
                        working.removeAll { $0 == tag }
                    } label: {
                        HStack(spacing: 6) {
                            Text(tag)
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.chipPlain, in: Capsule())
                    }
                    .accessibilityLabel("Remove \(tag)")
                }
            }
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Found on this phone")
            FlowRow(spacing: 8) {
                ForEach(extracted, id: \.self) { tag in
                    Chip(text: tag, background: .chipPlain, emphasis: true)
                }
            }
            Text("Written by the phone when it read this entry. Left alone by anything you do here.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Editing

    /// Lowercased and squeezed, because "Kitchen Table" and "kitchen table" are one tag and an
    /// archive that thinks otherwise ends up with both.
    private var normalized: String {
        typed
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func commit() {
        let tag = normalized
        guard !tag.isEmpty else { return }
        // Silently a no-op rather than an error: retyping a tag that is already there is a
        // reasonable thing to do and nothing went wrong.
        if !working.contains(tag) { working.append(tag) }
        typed = ""
        fieldFocused = true
    }

    private func save() async {
        guard let entry, changed else { return }
        saving = true
        notice = nil
        defer { saving = false }
        do {
            let response = try await api.updateEntry(
                id: entryId,
                changes: EntryChanges(
                    tags: .set(working.map { EntryTagWrite(name: $0, source: .user) })
                )
            )
            // The server's answer, not the working copy — it owns the set, including any
            // `device_ai` rows this write deliberately did not mention.
            entry.applyServerResponse(response)
            try? context.save()
            dismiss()
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }
}
