import SwiftData
import SwiftUI

/// One entry, in full: what was captured, what was asked, what was written, and when.
///
/// It renders from the cache the moment it opens and fetches `GET /entries/{id}` behind that,
/// because the list already holds almost everything this screen needs. What the detail call adds
/// is the two things a list row does not carry — the originating prompt, and the transcripts the
/// phone wrote back — and neither of them is worth a spinner over content that is already here.
struct EntryDetailScreen: View {
    let entryId: UUID
    let childId: UUID
    let api: APIClient
    let openComposer: (ComposerRequest) -> Void
    /// Pop back to the list. Called after a delete, so the row is gone from both screens at once.
    let onDeleted: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// The child the quoted prompt is about.
    @Environment(\.promptSubject) private var promptSubject

    @Query private var entries: [Entry]
    @Query private var media: [Media]
    /// For the prompt block, when the detail fetch has not landed yet. See `displayPrompt`.
    @Query private var assignments: [Assignment]

    @State private var notice: String?
    @State private var confirmingDelete = false
    @State private var viewing: ViewerRequest?
    /// A sealed letter the parent has chosen to open, for this viewing only. Nothing is
    /// persisted: the seal is the archive's, and unsealing it is a decision made each time.
    @State private var unsealed = false

    private let staging = StagingStore()

    init(
        entryId: UUID,
        childId: UUID,
        api: APIClient,
        openComposer: @escaping (ComposerRequest) -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.entryId = entryId
        self.childId = childId
        self.api = api
        self.openComposer = openComposer
        self.onDeleted = onDeleted
        _entries = Query(filter: #Predicate<Entry> { $0.id == entryId })
        _media = Query(
            filter: #Predicate<Media> { $0.entryId == entryId && $0.deletedAt == nil },
            sort: [SortDescriptor(\Media.createdAt, order: .forward)]
        )
        _assignments = Query(filter: #Predicate<Assignment> { $0.childId == childId })
    }

    private var entry: Entry? { entries.first }

    var body: some View {
        ScrollView {
            if let entry {
                content(entry)
                    .padding(Layout.screenMargin)
            } else {
                // The row is gone — deleted here or on another phone. Said plainly.
                missing
            }
        }
        .background(Color.canvas)
        // The day it happened, in the bar. The timeline's root hides its bar, so without a title
        // this screen's back chevron and menu float as bare circles on cream — chrome that looks
        // accidental rather than designed. The date is also the one thing worth keeping visible
        // once the metadata row has scrolled away, and it is `occurred_at`, never `created_at`.
        .navigationTitle(entry.map { DayHeaderText.compact($0.occurredAt) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: entryId) { await load() }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It leaves the timeline on every device. Photos and video go with it.")
        }
        .fullScreenCover(item: $viewing) { request in
            MediaViewerScreen(
                mediaId: request.id,
                kind: request.kind,
                localFile: request.localFile,
                api: api
            )
        }
    }

    // MARK: Body

    /// v3's reading order: the artifact, then the question it answered, then the answer.
    ///
    /// The transcript moved out of the player and down here, set as body copy under its own
    /// label. His words are what the archive is keeping — they get reading type, not caption
    /// type bolted to a control.
    @ViewBuilder
    private func content(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.unlockAtAge != nil, !unsealed {
                sealedCard(entry)
            } else {
                hero
                if let prompt = displayPrompt(entry) {
                    promptBlock(prompt, on: entry.occurredAt)
                        .padding(.top, heroIsPresent ? 18 : 0)
                }
                writtenContent(entry)
                if let transcript = Self.transcript(in: media) {
                    transcriptSection(transcript)
                }
                metadata(entry)
                tags(entry)
            }
            if let notice {
                Text(notice)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The top block: pictures if there are any, else the voice player, else nothing.
    ///
    /// Nothing is the ordinary case, not the broken one — a written entry and a did-it entry
    /// have no artifact, and the screen opens on the prompt instead.
    @ViewBuilder
    private var hero: some View {
        if !pictures.isEmpty {
            gallery
        } else if let voice = voiceMedia {
            VoicePlayerView(
                mediaId: voice.id,
                durationSeconds: voice.durationSeconds,
                transcript: nil,
                localFile: stagedOriginal(voice),
                api: api
            )
        }
    }

    private var heroIsPresent: Bool { !pictures.isEmpty || voiceMedia != nil }

    /// The cached prompt, falling back to the assignment this entry completed.
    ///
    /// `promptBody` arrives with `GET /entries/{id}` and is the better source — it is the prompt
    /// as the server records it. The assignment is what the timeline card quoted a moment ago,
    /// and using it here means the block does not disappear when the detail fetch has not landed
    /// yet, which would read as the screen losing something on the way in.
    ///
    /// **Rendered here, at the last moment before a human reads it.** Both sources hold the body
    /// with its tokens intact — `Entry.promptBody` and `Assignment.body` are caches of what the
    /// server serves, not of what was once displayed — which is what lets an entry written three
    /// years ago re-render correctly when the answer changes today.
    private func displayPrompt(_ entry: Entry) -> String? {
        let raw: String?
        if let cached = entry.promptBody, !cached.isEmpty {
            raw = cached
        } else if let assignmentId = entry.assignmentId {
            raw = assignments.first { $0.id == assignmentId }?.body
        } else {
            raw = nil
        }
        return raw.map { PromptTokens.render($0, for: promptSubject) }
    }

    /// Photos and video. Audio is not here — it gets a player of its own below the text.
    private var pictures: [Media] {
        media.filter { $0.mediaKind == .photo || $0.mediaKind == .video }
    }

    private var voiceMedia: Media? {
        media.first { $0.mediaKind == .audio }
    }

    /// The words to set under the player, or nothing at all.
    ///
    /// A static rule rather than a branch inside `content`, for the same reason `EntryCardModel`
    /// is a value type: it is the difference between a layout decision that can be asserted and
    /// one that can only be looked at. **The absence case is the one worth guarding** — an audio
    /// entry with no transcript is a complete entry, not a deficient one, and this screen must
    /// render it exactly as it did before transcription existed: no heading, no empty block, no
    /// "transcription pending" anything.
    ///
    /// Empty and nil collapse to the same nothing on purpose. A recording of a child who said
    /// nothing settles with no words, and a heading over a blank line would be the archive
    /// implying something is missing when nothing is.
    static func transcript(in media: [Media]) -> String? {
        guard let text = media.first(where: { $0.mediaKind == .audio })?.transcript,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    @ViewBuilder
    private var gallery: some View {
        if pictures.count == 1, let only = pictures.first {
            detailMedia(only)
        } else {
            TabView {
                ForEach(pictures, id: \.id) { item in
                    detailMedia(item).padding(.bottom, 28)
                }
            }
            .tabViewStyle(.page)
            .frame(height: galleryHeight)
        }
    }

    /// 4:3 plus room for the page dots, which sit inside the TabView's own frame.
    private var galleryHeight: CGFloat { 300 }

    private func detailMedia(_ item: Media) -> some View {
        DetailMediaView(
            mediaId: item.id,
            kind: item.mediaKind,
            durationSeconds: item.durationSeconds,
            api: api,
            localFile: stagedOriginal(item)
        ) {
            viewing = ViewerRequest(
                id: item.id,
                kind: item.mediaKind,
                localFile: stagedOriginal(item)
            )
        }
    }

    /// The question, in a block tinted to the kind of entry that answered it.
    ///
    /// A filled block here, where the card uses a rule and an indent: on the detail screen the
    /// prompt is one of two or three things on the page and can hold its own shape.
    ///
    /// The date shown is the entry's `occurred_at` and it is labelled as such. The prompt's own
    /// date — when the assignment landed — is not in `GET /entries/{id}`, and inventing one for
    /// a permanent archive is worse than saying the thing that is true.
    private func promptBlock(_ prompt: String, on date: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Answered \(DayHeaderText.full(date))")
                .typeRole(.label)
                .foregroundStyle(Color.inkFaint)
            Text(prompt)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(promptTint, in: RoundedRectangle(cornerRadius: Layout.quoteBlockRadius, style: .continuous))
    }

    /// Colour carries meaning here too — periwinkle for voice and writing, sage for did-it,
    /// terracotta for anything with a picture in it.
    private var promptTint: Color {
        switch entry?.type {
        case .didIt: .sage
        case .audio, .text: .periwinkleSoft
        default: .terracottaSoft
        }
    }

    @ViewBuilder
    private func writtenContent(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = entry.title, !title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if entry.type == .didIt {
                        CompletionCheck(isComplete: true, diameter: 22, tint: .sageInk, check: .sage)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    }
                    Text(title)
                        .typeRole(.detailTitle)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let body = entry.body, !body.isEmpty {
                Text(body)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.title == nil, media.isEmpty {
                // A did-it entry with no note. Complete, and it says so rather than rendering
                // as a screen with nothing on it.
                HStack(spacing: 10) {
                    CompletionCheck(isComplete: true, diameter: 26, tint: .sageInk, check: .sage)
                    Text("We did it")
                        .typeRole(.detailTitle)
                        .foregroundStyle(Color.ink)
                }
            }
        }
        .padding(.top, 20)
    }

    /// What was actually said, under a quiet label.
    ///
    /// Body type, not caption type. The phone transcribed this on device and
    /// `PATCH /media/{id}/derived` made it permanent — it is the artifact, not a note about one.
    private func transcriptSection(_ transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .typeRole(.label)
                .foregroundStyle(Color.inkFaint)
                .accessibilityAddTraits(.isHeader)
            Text(transcript)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 14)
    }

    /// The facts, as a key-and-value list above the tags.
    private func metadata(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider().overlay(Color.border).padding(.bottom, 7)

            if let months = entry.childAgeMonths {
                metaRow("Age at the time") {
                    Text(AgeText.long(months))
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.periwinkle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.periwinkleSoft, in: Capsule())
                }
            }
            metaRow("Date") { metaValue(DayHeaderText.full(entry.occurredAt)) }
            if pictures.count > 1 {
                metaRow(picturesLabel) { metaValue("\(pictures.count)") }
            }
            if let seconds = voiceMedia?.durationSeconds {
                metaRow("Length") { metaValue(DurationText.clock(seconds)) }
            }
            if entry.sync != .synced {
                // A network fact, not an error and not a loss.
                metaRow("Saved") { metaValue("Here — it'll sync when you're back on") }
            }
        }
        .padding(.top, 24)
    }

    /// "Photos", "Videos", or "Items" when the entry holds both. Never "Media", which is a word
    /// for the people who build the app rather than the people who use it.
    private var picturesLabel: String {
        if pictures.allSatisfy({ $0.mediaKind == .photo }) { return "Photos" }
        if pictures.allSatisfy({ $0.mediaKind == .video }) { return "Videos" }
        return "Items"
    }

    private func metaRow<Value: View>(_ key: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
            Spacer(minLength: 8)
            value()
        }
        .accessibilityElement(children: .combine)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text)
            .typeRole(.metadata)
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.trailing)
    }

    @ViewBuilder
    private func tags(_ entry: Entry) -> some View {
        if !entry.tagNames.isEmpty {
            HStack(spacing: 6) {
                ForEach(entry.tagNames, id: \.self) { tag in
                    Chip(text: tag, background: .chipPlain, emphasis: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
        }
    }

    // MARK: Sealed

    /// Calm and deliberate. It says what it is, when it opens, and that the parent may open it
    /// anyway — because they wrote it, and a lock the author cannot pick is a lock on the wrong
    /// person.
    private func sealedCard(_ entry: Entry) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.terracottaDeep)
            Text(entry.title ?? "A letter")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text(entry.unlockAtAge.map { "Sealed until \($0)." } ?? "Sealed.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
            Text("Written on \(DayHeaderText.full(entry.occurredAt)), and waiting.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button("Open it") { withAnimation(Motion.cardToDone) { unsealed = true } }
                .typeRole(.cardTitle)
                .foregroundStyle(Color.terracotta)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Gradients.wash, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Text("That's no longer here")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text("This entry was deleted.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(Layout.screenMargin)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { edit() } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Color.terracotta)
            }
            .disabled(entry == nil)
            .accessibilityLabel("Entry options")
        }
    }

    // MARK: Actions

    /// The existing composer, in edit mode. There is one editor in this app and this is not a
    /// second one — the same rule the Today screen's done-card edit follows.
    private func edit() {
        guard let entry else { return }
        openComposer(
            ComposerRequest(
                childId: childId,
                assignment: nil,
                mode: entry.body?.isEmpty == false ? .text : .didIt,
                editing: entry.id
            )
        )
    }

    private func delete() async {
        guard let entry else { return }
        await EntryCache.delete(entry, api: api, in: context)
        onDeleted()
        dismiss()
    }

    /// Fill in what only the detail call carries: the prompt, and the transcripts.
    private func load() async {
        do {
            EntryCache.upsert(try await api.entry(id: entryId), into: context)
            try? context.save()
            notice = nil
        } catch let error as APIError where error.code == .notFound {
            // Gone server-side. Mark it here too rather than showing a row that no longer
            // exists anywhere else.
            if let entry, entry.deletedAt == nil {
                EntryCache.markDeleted(entry, in: context)
                entry.deletionPending = false
                try? context.save()
            }
        } catch let error as APIError {
            // The cache is already on screen. Offline is not a failure worth a dialog.
            notice = entry == nil ? error.userMessage : nil
        } catch {
            notice = entry == nil ? error.localizedDescription : nil
        }
    }

    /// The staged original, when this phone still has it. Nil once the sweep has collected it,
    /// which is the ordinary case for anything older than a few minutes.
    private func stagedOriginal(_ item: Media) -> URL? {
        guard let ext = item.stagedExtension else { return nil }
        let url = staging.originalURL(for: item.id, ext: ext)
        return staging.exists(url) ? url : nil
    }
}

/// What the fullscreen cover needs. `Identifiable` so it can drive `fullScreenCover(item:)`,
/// which is the presentation that cannot get out of step with its content.
struct ViewerRequest: Identifiable, Equatable {
    let id: UUID
    let kind: PromptKind
    let localFile: URL?
}
