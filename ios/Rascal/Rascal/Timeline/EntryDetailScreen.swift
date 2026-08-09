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

    @Query private var entries: [Entry]
    @Query private var media: [Media]

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

    @ViewBuilder
    private func content(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if entry.unlockAtAge != nil, !unsealed {
                sealedCard(entry)
            } else {
                if !pictures.isEmpty { gallery }
                if let prompt = entry.promptBody { promptBlock(prompt, on: entry.occurredAt) }
                writtenContent(entry)
                if let voice = voiceMedia { voiceSection(voice) }
                metadata(entry)
            }
            if let notice {
                Text(notice)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Photos and video. Audio is not here — it gets a player of its own below the text.
    private var pictures: [Media] {
        media.filter { $0.mediaKind == .photo || $0.mediaKind == .video }
    }

    private var voiceMedia: Media? {
        media.first { $0.mediaKind == .audio }
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
            durationSeconds: item.durationSeconds
        ) {
            viewing = ViewerRequest(
                id: item.id,
                kind: item.mediaKind,
                localFile: stagedOriginal(item)
            )
        }
    }

    /// A soft quoted block, with the day it was answered.
    ///
    /// The date shown is the entry's `occurred_at` and it is labelled as such. The prompt's own
    /// date — when the assignment landed — is not in `GET /entries/{id}`, and inventing one for
    /// a permanent archive is worse than saying the thing that is true.
    private func promptBlock(_ prompt: String, on date: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Color.terracotta.opacity(0.35))
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt)
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Answered \(DayHeaderText.full(date))")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
    }

    @ViewBuilder
    private func writtenContent(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = entry.title, !title.isEmpty {
                Text(title)
                    .typeRole(.title)
                    .foregroundStyle(Color.ink)
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
                    CompletionCheck(isComplete: true, diameter: 26)
                    Text("We did it")
                        .typeRole(.title)
                        .foregroundStyle(Color.ink)
                }
            }
        }
    }

    private func voiceSection(_ item: Media) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Voice")
            VoicePlayerView(
                mediaId: item.id,
                durationSeconds: item.durationSeconds,
                transcript: item.transcript,
                localFile: stagedOriginal(item),
                api: api
            )
        }
    }

    private func metadata(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.border)
            HStack(spacing: 6) {
                if let months = entry.childAgeMonths {
                    Chip(text: AgeText.chip(months), background: .border)
                }
                ForEach(entry.tagNames, id: \.self) { tag in
                    Chip(text: tag, background: .border)
                }
                Spacer(minLength: 0)
            }
            Text(DayHeaderText.full(entry.occurredAt))
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
            if entry.sync != .synced {
                // A network fact, not an error and not a loss.
                Text("Saved here. It'll sync when you're back on.")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
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
