import PhotosUI
import SwiftData
import SwiftUI

struct ComposerRequest: Identifiable {
    let id = UUID()
    let childId: UUID
    let assignment: AssignmentResponse?
    let mode: CompletionMode
}

/// Writing an entry. Opens knowing its completion mode, because "we did it" and "write it" are
/// different gestures, not the same form with a different label.
struct ComposerView: View {
    let request: ComposerRequest
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Backdating is a first-class flow, so this is a real choice and not a hidden setting.
    @State private var occurredAt = Date()
    @State private var showDatePicker = false
    @State private var text = ""
    @State private var didIt = false
    @State private var saving = false
    @State private var notice: String?
    @FocusState private var writing: Bool

    // Capture
    @State private var drafts: [MediaDraft] = []
    @State private var picking: [PhotosPickerItem] = []
    @State private var showCamera = false
    /// Set once the parent has moved the date themselves, so importing another photo cannot
    /// silently overwrite a deliberate choice.
    @State private var dateWasChosen = false
    /// True while the composer itself is moving the date, so the change is not mistaken for
    /// the parent choosing one.
    @State private var importing = false
    private let staging = StagingStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DatePill(date: $occurredAt, isExpanded: $showDatePicker)

                    if let assignment = request.assignment {
                        quotedPrompt(assignment)
                    }

                    switch request.mode {
                    case .text: writeIt
                    case .didIt: didItControl
                    case .media, .unknown: captureIt
                    }

                    if let notice {
                        Text(notice)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                .padding(Layout.screenMargin)
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving" : "Save") { Task { await save() } }
                        .foregroundStyle(canSave ? Color.terracotta : Color.inkMuted)
                        .disabled(!canSave || saving)
                }
            }
        }
        .presentationDragIndicator(.visible)
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in importCaptured(data) }
                .ignoresSafeArea()
        }
        #endif
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPicked(items) }
        }
        .onChange(of: occurredAt) { _, _ in
            // Only a tap counts as choosing. EXIF import sets this too, and that must not
            // look like a decision the parent made.
            if !importing { dateWasChosen = true }
        }
    }

    // MARK: Importing

    /// Picked photos are staged and processed one at a time rather than in parallel.
    /// A five-photo import is a handful of seconds either way, and serial keeps peak memory
    /// to one decoded image — an eight-photo parallel import of 48MP HEICs is how a composer
    /// gets killed mid-selection.
    private func importPicked(_ items: [PhotosPickerItem]) async {
        importing = true
        defer { importing = false; picking = [] }

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            append(fromData: data)
        }
        adoptExifDateIfUnchosen()
    }

    private func importCaptured(_ data: Data) {
        importing = true
        append(fromData: data)
        importing = false
        adoptExifDateIfUnchosen()
    }

    private func append(fromData data: Data) {
        guard let draft = try? MediaDraftBuilder.make(from: data, store: staging) else {
            // A file the pipeline cannot read is not silently dropped — but it is also not an
            // alarm, because nothing was lost: the photo is still in the library.
            notice = "One of those couldn't be read, so it wasn't added."
            return
        }
        drafts.append(draft)
    }

    /// A library photo files the entry on the day it was taken. That is the camera-roll
    /// backfill story, and it is the whole reason `occurred_at` and `created_at` are separate.
    /// A date the parent picked themselves always wins.
    private func adoptExifDateIfUnchosen() {
        guard !dateWasChosen else { return }
        let suggested = MediaDraftBuilder.suggestedOccurredAt(for: drafts)
        if abs(suggested.timeIntervalSince(occurredAt)) > 1 {
            importing = true
            occurredAt = suggested
            importing = false
        }
    }

    private func remove(_ draft: MediaDraft) {
        drafts.removeAll { $0.id == draft.id }
        // The staged bytes go with it. Nothing references them and the sweep would collect
        // them as orphans anyway; removing now keeps the directory honest.
        staging.removeAll(for: draft.id)
    }

    // MARK: Modes

    /// A clean field on canvas, with nothing competing with it.
    private var writeIt: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("What happened")
            TextEditor(text: $text)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180, alignment: .topLeading)
                .padding(10)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                )
                .focused($writing)
        }
    }

    /// This has to read as complete and legitimate, not degraded. Half the library produces no
    /// artifact, and a note on a did-it mission stays a did-it entry — the server derives the
    /// type and will not reclassify it because the parent wrote something.
    private var didItControl: some View {
        VStack(spacing: 16) {
            Button {
                didIt.toggle()
                if didIt { Haptics.completion() }
            } label: {
                CompletionCheck(isComplete: didIt, diameter: 96)
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel(didIt ? "Done" : "Mark as done")
            .accessibilityAddTraits(didIt ? [.isSelected, .isButton] : .isButton)

            Text(didIt ? "Done." : "Tap when you've done it.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Add a note — optional")
                TextField("Anything worth remembering", text: $text, axis: .vertical)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .lineLimit(3...6)
                    .padding(12)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                            .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Photo capture. Video and audio are not this phase, and the card says so rather than
    /// offering a button that cannot deliver.
    @ViewBuilder
    private var captureIt: some View {
        if drafts.isEmpty {
            captureChoices
        } else {
            MediaPreviewRow(
                drafts: drafts,
                onRemove: remove,
                onAddMore: { showCamera = false }
            )
            addAnother
        }

        if request.assignment?.promptKind == .video {
            // The scheduler served a video mission and this phase cannot complete one. Said
            // plainly: the Today screen must not lie about what was served, and neither
            // should this.
            Text("Video arrives next phase. You can add photos or write about it now.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }

        writeIt
    }

    private var captureChoices: some View {
        HStack(spacing: 10) {
            PhotosPicker(
                selection: $picking,
                maxSelectionCount: 10,
                matching: .images,
                photoLibrary: .shared()
            ) {
                choiceTile(symbol: "photo.on.rectangle", label: "Choose")
            }
            .buttonStyle(TapScaleButtonStyle())

            #if canImport(UIKit)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: {
                    choiceTile(symbol: "camera", label: "Take one")
                }
                .buttonStyle(TapScaleButtonStyle())
            }
            #endif
        }
    }

    private var addAnother: some View {
        PhotosPicker(
            selection: $picking,
            maxSelectionCount: 10,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Text("Choose from library")
                .typeRole(.metadata)
                .foregroundStyle(Color.terracotta)
        }
    }

    private func choiceTile(symbol: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
            Text(label).typeRole(.cardTitle)
        }
        .foregroundStyle(Color.terracotta)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color.terracottaSoft, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
    }

    private func quotedPrompt(_ assignment: AssignmentResponse) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.terracotta.opacity(0.35))
                .frame(width: 3)
                .clipShape(Capsule())
            Text(assignment.body)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
    }

    // MARK: Saving

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        switch request.mode {
        case .didIt: didIt
        // A photo alone is a complete entry — the archive is full of them, and requiring a
        // caption would be requiring homework.
        case .media, .unknown: !drafts.isEmpty || !trimmed.isEmpty
        default: !trimmed.isEmpty
        }
    }

    /// Local first, network second. The row exists in SwiftData before any request goes out, so
    /// a failure is never lost work and never a lost-work error message.
    private func save() async {
        saving = true
        defer { saving = false }

        let entry = Entry(
            childId: request.childId,
            assignmentId: request.assignment?.id,
            occurredAt: occurredAt,
            body: trimmed.isEmpty ? nil : trimmed
        )
        context.insert(entry)

        // Media rows are created alongside the entry, before any request. The files are
        // already staged, so a force quit right here loses nothing: the sweep finds both.
        for draft in drafts {
            let media = Media(
                id: draft.id,
                entryId: entry.id,
                kind: "photo",
                contentType: draft.contentType,
                byteCount: draft.byteCount,
                stagedExtension: draft.fileExtension,
                capturedAt: draft.capturedAt
            )
            media.hasThumbnail = true
            context.insert(media)
        }
        try? context.save()

        do {
            let response = try await api.createEntry(entry)
            entry.applyServerResponse(response)
            try? context.save()
            dismiss()
        } catch let error as APIError {
            // The one real user-facing failure: the entry saves, it just no longer completes
            // that assignment. Said plainly and without alarm.
            if error.code == .assignmentExpired {
                entry.assignmentId = nil
                entry.sync = .pending
                try? context.save()
                notice = error.userMessage
                return
            }
            // Everything else is a network fact, not a failure the parent needs to act on.
            // The entry is already in SwiftData; `EntrySync.sweep()` re-sends it on the next
            // foreground with the same idempotency key, so a replay is the original write
            // rather than a second row.
            //
            // Deliberately no message: the design system says an entry saved locally but not
            // yet synced is never presented as an error or a loss, and it is neither. Today
            // shows a quiet count of anything still in flight. (The previous version set a
            // notice here and dismissed in the same breath, so the text was never rendered —
            // code that looked like it communicated and did not.)
            entry.sync = .failed
            try? context.save()
            dismiss()
        } catch {
            entry.sync = .failed
            try? context.save()
            dismiss()
        }
    }
}

/// The backdating affordance, in the composer header where it's obvious.
struct DatePill: View {
    @Binding var date: Date
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.tap) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(label)
                        .typeRole(.metadata)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel("Entry date, \(label). Tap to change.")

            if isExpanded {
                DatePicker(
                    "Entry date",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(.terracotta)
                .labelsHidden()
            }
        }
    }

    private var label: String {
        Calendar.current.isDateInToday(date)
            ? "Today"
            : date.formatted(.dateTime.day().month(.wide).year())
    }
}
