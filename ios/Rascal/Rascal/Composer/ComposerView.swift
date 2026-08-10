import PhotosUI
import SwiftData
import SwiftUI

struct ComposerRequest: Identifiable {
    let id = UUID()
    let childId: UUID
    let assignment: AssignmentResponse?
    let mode: CompletionMode
    /// Set when opening an existing entry to edit. Date, title, and body are editable; media
    /// is shown read-only, because adding or removing files after save is a later phase.
    var editing: UUID?

    var isEditing: Bool { editing != nil }
}

/// Writing an entry. Opens knowing its completion mode, because "we did it" and "write it" are
/// different gestures, not the same form with a different label.
struct ComposerView: View {
    let request: ComposerRequest
    let api: APIClient

    /// Written by hand for one property. `seal` has to start from the assignment — sealed, at
    /// the prompt's own age — and a `@State` default cannot see the request. Setting it in
    /// `.task` instead would render the toggle off for a frame on the one screen where "on" is
    /// the entire point.
    init(request: ComposerRequest, api: APIClient) {
        self.request = request
        self.api = api
        _seal = State(initialValue: .initial(for: request.assignment, isEditing: request.isEditing))
    }

    /// Whether this entry seals, and at what age. Only ever shown for a `letter` prompt.
    @State private var seal: SealSetting

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
    /// Set once this sheet has committed an entry to the local store.
    ///
    /// **Save must not be able to write a second one.** The sheet deliberately stays open after a
    /// save that has something to report — an expired assignment, a seal the archive kept — and
    /// every tap of Save builds a *new* `Entry` with a new id, so the idempotency key that makes a
    /// network retry safe would not catch it. Two rows in a permanent archive from one act of
    /// writing is the kind of thing nobody notices until it is old.
    @State private var committed = false
    @FocusState private var writing: Bool

    // Capture
    @State private var drafts: [MediaDraft] = []
    @State private var picking: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showRecorder = false
    /// Set once the parent has moved the date themselves, so importing another photo cannot
    /// silently overwrite a deliberate choice.
    @State private var dateWasChosen = false
    /// True while the composer itself is moving the date, so the change is not mistaken for
    /// the parent choosing one.
    @State private var importing = false
    /// Media already attached to an entry being edited. Read-only: adding or removing files
    /// after save is a later phase, and showing them is better than pretending they are gone.
    @State private var existingMedia: [Media] = []
    private let staging = StagingStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DatePill(date: $occurredAt, isExpanded: $showDatePicker)

                    if let assignment = request.assignment {
                        quotedPrompt(assignment)
                    }

                    if !existingMedia.isEmpty { attachedMedia }

                    switch request.mode {
                    case .didIt:
                        didItControl
                    case .media, .unknown:
                        captureIt
                    case .text:
                        // A freeform entry is the camera-roll backfill surface — it is where
                        // someone sits down with a year of photos — so it attaches media too.
                        // Deliberately no video anywhere: capture for it does not exist, and
                        // an affordance leading nowhere is worse than its absence.
                        if request.assignment == nil { freeformCapture }
                        writeIt
                    }

                    // After the writing, before the save. The letter is the thing; when it
                    // opens is what you decide once it exists.
                    if SealSetting.isOffered(for: request.assignment, isEditing: request.isEditing) {
                        SealControl(seal: $seal)
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
                        .foregroundStyle(canSave && !committed ? Color.terracotta : Color.inkMuted)
                        .disabled(!canSave || saving || committed)
                }
            }
        }
        .task {
            loadForEditing()
            // An audio mission lands on the recorder with nothing in between. The brief is
            // fifteen seconds, one-handed, and a setup screen is most of that budget.
            if request.assignment?.promptKind == .audio, request.mode == .media,
               !request.isEditing, drafts.isEmpty {
                showRecorder = true
            }
        }
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showRecorder) {
            AudioRecorderSheet(
                onFinish: { recording in
                    drafts.append(MediaDraftBuilder.makeAudio(recording))
                    showRecorder = false
                },
                onCancel: { showRecorder = false }
            )
        }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { data in importCaptured(data) },
                onCaptureVideo: { url in Task { await importCapturedVideo(url) } },
                wantsVideo: isVideoPrompt
            )
            .ignoresSafeArea()
        }
        #endif
        .photosPicker(
            isPresented: $showLibrary,
            selection: $picking,
            maxSelectionCount: 10,
            matching: isVideoPrompt ? .videos : .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
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

    /// Populate from the entry being edited. Runs once; the composer is presented fresh each
    /// time, so there is no stale-state case to guard.
    private func loadForEditing() {
        guard let editingId = request.editing,
              let entry = try? context.fetch(
                  FetchDescriptor<Entry>(predicate: #Predicate { $0.id == editingId })
              ).first
        else { return }

        importing = true
        occurredAt = entry.occurredAt
        text = entry.body ?? ""
        didIt = true
        importing = false
        // A date already chosen once must not be overwritten by anything.
        dateWasChosen = true

        existingMedia = (try? context.fetch(
            FetchDescriptor<Media>(predicate: #Predicate { $0.entryId == editingId })
        )) ?? []
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
            // A video is transferred as a file, never as Data — a picked 4K minute is hundreds
            // of megabytes and loading it into memory to hand it along is how the composer gets
            // killed mid-selection.
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    do {
                        drafts.append(try await MediaDraftBuilder.makeVideo(fileAt: movie.url, store: staging))
                    } catch {
                        notice = "One of those videos couldn't be read, so it wasn't added."
                    }
                    // The picker's copy has served its purpose; the transcode is in staging.
                    try? FileManager.default.removeItem(at: movie.url)
                }
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            append(fromData: data)
        }
        adoptExifDateIfUnchosen()
    }

    /// A video captured in-app. The original goes back to the camera roll before anything
    /// else — it exists nowhere else, and the transcode about to happen is one-way.
    private func importCapturedVideo(_ url: URL) async {
        importing = true
        await VideoPipeline.preserveOriginal(at: url)
        do {
            drafts.append(try await MediaDraftBuilder.makeVideo(fileAt: url, store: staging))
        } catch {
            notice = "That video couldn't be read, so it wasn't added."
        }
        importing = false
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
            SectionLabel(request.assignment == nil ? "What happened" : "Your answer")
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

    /// Capture, whichever kind the mission asked for.
    @ViewBuilder
    private var captureIt: some View {
        if drafts.isEmpty {
            captureChoices
        } else {
            MediaPreviewRow(
                drafts: drafts,
                onRemove: remove,
                // Was a no-op: the tile rendered and did nothing. It opens the same picker
                // as "Choose from library", because that is plainly what a + on a photo row
                // promises.
                onAddMore: { showLibrary = true }
            )
            addAnother
        }

        writeIt
    }

    /// Photo and voice attachment on a freeform entry. Framed like the prompted composer rather
    /// than left bare — this is a whole mission category, not an afterthought.
    @ViewBuilder
    private var freeformCapture: some View {
        if drafts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Add photos or a voice note — optional")
                captureChoices
            }
        } else {
            MediaPreviewRow(drafts: drafts, onRemove: remove, onAddMore: { showLibrary = true })
            addAnother
        }
    }

    /// A video prompt gets a camera that actually records video, and a picker that offers
    /// videos. Previously it offered a stills camera above copy explaining video was not
    /// ready, which is the lie the device session caught twice.
    private var isVideoPrompt: Bool { request.assignment?.promptKind == .video }
    private var isAudioPrompt: Bool { request.assignment?.promptKind == .audio }

    /// What a mission of this kind can be answered with.
    ///
    /// An audio mission offers the microphone and nothing else — it opened straight into the
    /// recorder, and this is the way back in after a cancel. Everything else keeps the photo
    /// affordances and gains a voice tile, because a voice note is a legitimate answer to
    /// almost anything and to a freeform entry especially.
    @ViewBuilder
    private var captureChoices: some View {
        if isAudioPrompt {
            Button { showRecorder = true } label: {
                choiceTile(symbol: "mic", label: "Record")
            }
            .buttonStyle(TapScaleButtonStyle())
        } else {
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
                        choiceTile(
                            symbol: isVideoPrompt ? "video" : "camera",
                            label: isVideoPrompt ? "Record" : "Take a photo"
                        )
                    }
                    .buttonStyle(TapScaleButtonStyle())
                }
                #endif

                if !isVideoPrompt {
                    Button { showRecorder = true } label: {
                        choiceTile(symbol: "mic", label: "Voice")
                    }
                    .buttonStyle(TapScaleButtonStyle())
                }
            }
        }
    }

    /// Adding to an entry that already has something on it. Both, because an entry may hold
    /// photos and a voice note together — the media model has always allowed it.
    private var addAnother: some View {
        HStack(spacing: 16) {
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
            Button("Add a voice note") { showRecorder = true }
                .typeRole(.metadata)
                .foregroundStyle(Color.terracotta)
            Spacer(minLength: 0)
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

    /// What is already attached. Read-only by design this phase.
    private var attachedMedia: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(existingMedia.count == 1 ? "1 photo" : "\(existingMedia.count) photos")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(existingMedia, id: \.id) { media in
                        thumbnail(for: media)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for media: Media) -> some View {
        let url = staging.thumbnailURL(for: media.id)
        Group {
            #if canImport(UIKit)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // The local cache is disposable — the bytes are in storage and reachable
                // through GET /media/{id}/url. A neutral tile is honest; an error is not.
                Color.surface
            }
            #else
            Color.surface
            #endif
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
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
        // An edit may be date-only, which is the whole point of backdating.
        if request.isEditing { return true }
        // Explicit `return`: with a statement above it, the switch is no longer the body's
        // single expression and cannot be implicitly returned.
        // A photo alone is a complete entry — the archive is full of them, and requiring a
        // caption would be requiring homework. This applies to *every* mode that can hold
        // media, which includes the freeform composer: it opens in `.text` mode and used to
        // fall through to the text-only rule, so attaching a photo and pressing Save did
        // nothing at all. Save was disabled and said nothing about why.
        return switch request.mode {
        case .didIt: didIt
        default: !drafts.isEmpty || !trimmed.isEmpty
        }
    }

    /// Local first, network second. The row exists in SwiftData before any request goes out, so
    /// a failure is never lost work and never a lost-work error message.
    private func save() async {
        saving = true
        defer { saving = false }

        if let editingId = request.editing {
            await saveEdit(editingId)
            return
        }

        let entry = Entry(
            childId: request.childId,
            assignmentId: request.assignment?.id,
            occurredAt: occurredAt,
            body: trimmed.isEmpty ? nil : trimmed,
            // Nil for everything that is not a sealed letter, which is almost everything.
            unlockAtAge: seal.unlockAtAge
        )
        // Cache the prompt at the moment it is answered.
        //
        // The timeline card quotes the prompt the entry answered, and there are only two other
        // places it could come from: `GET /entries/{id}`, which the list never calls, and a
        // cached `Assignment`, which only `/sync` writes and `/sync` ships disabled. So without
        // this the quote on an entry written today would not appear until the parent opened it.
        //
        // The composer already has the sentence in hand — it is on screen above the field the
        // parent is typing into — so writing it down costs nothing and makes the card correct
        // offline, immediately, and for good.
        if let assignment = request.assignment {
            entry.promptBody = assignment.body
            entry.promptKind = assignment.kind
        }
        context.insert(entry)
        // From here the entry exists locally whatever the network does, so this sheet has had
        // its one save. `EntrySync` owns every retry from now on.
        committed = true

        // Media rows are created alongside the entry, before any request. The files are
        // already staged, so a force quit right here loses nothing: the sweep finds both.
        for draft in drafts {
            let media = Media(
                id: draft.id,
                entryId: entry.id,
                // The server decides single-PUT versus multipart from the byte count it is
                // given, and derives entry_type from the kind — so both have to be honest.
                kind: draft.kind,
                contentType: draft.contentType,
                byteCount: draft.byteCount,
                stagedExtension: draft.fileExtension,
                capturedAt: draft.capturedAt,
                durationSeconds: draft.durationSeconds
            )
            // From the draft, not unconditionally. Audio has no thumbnail, and the staging
            // sweep reads this flag as permission to delete the only local copy of the file.
            media.hasThumbnail = draft.hasThumbnail
            context.insert(media)
        }
        try? context.save()

        do {
            let response = try await api.createEntry(entry)
            entry.applyServerResponse(response)
            try? context.save()
            if reportSealMismatch(entry) { return }
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

    /// An edit follows the same discipline as a creation: local first, then sync. The change
    /// is on screen before the request goes out, and a failure leaves it queued rather than
    /// lost.
    /// Say so if the archive kept a seal the parent turned off.
    ///
    /// `APIClient.createEntry` already tries to undo it — and does so for `EntrySync`'s offline
    /// re-send too, which is why that lives there and not here. This is only the part that needs
    /// a screen: if the correction did not land, `applyServerResponse` has copied the archive's
    /// value back onto the row, so the phone and the archive agree, and the only thing missing is
    /// telling the person who asked.
    ///
    /// Returns true when it kept the sheet open to say something.
    private func reportSealMismatch(_ entry: Entry) -> Bool {
        guard SealSetting.isOffered(for: request.assignment, isEditing: request.isEditing),
              !seal.isSealed,
              let sealedAt = entry.unlockAtAge
        else { return false }

        notice = "Saved, and it sealed at \(sealedAt). Leaving it open didn't reach the archive."
        return true
    }

    private func saveEdit(_ entryId: UUID) async {
        guard let entry = try? context.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { $0.id == entryId })
        ).first else { dismiss(); return }

        entry.occurredAt = occurredAt
        entry.body = trimmed.isEmpty ? nil : trimmed
        entry.updatedAt = Date()
        entry.sync = .pending
        try? context.save()
        dismiss()

        do {
            let response = try await api.updateEntry(entry)
            entry.applyServerResponse(response)
        } catch {
            // Queued. `EntrySync` sends it as a PATCH on the next sweep, because the row is
            // already known to the server.
            entry.sync = .failed
        }
        try? context.save()
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
                // The numerals inherit the ambient foreground, which here was `inkMuted` from
                // the surrounding metadata styling — light grey on cream, well under contrast
                // minimums, and effectively unreadable on a phone in daylight. The selected
                // date was fine because `tint` colours it separately, which is exactly why it
                // was easy to miss. `ink` is the palette's body colour and the right one.
                .foregroundStyle(Color.ink)
                .environment(\.colorScheme, .light)
                .padding(.horizontal, 4)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
            }
        }
    }

    private var label: String {
        Calendar.current.isDateInToday(date)
            ? "Today"
            : date.formatted(.dateTime.day().month(.wide).year())
    }
}
