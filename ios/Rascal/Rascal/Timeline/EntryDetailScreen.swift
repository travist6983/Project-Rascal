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
            } else {
                // The row is gone — deleted here or on another phone. Said plainly.
                missing
            }
        }
        // **The backdrop is the layer that changes; the sheet on top of it does not.** That is the
        // v2 grammar in one line — seven kinds of entry, one reading surface, and what sits behind
        // it is the only thing that varies.
        .background(backdrop.ignoresSafeArea())
        // Over a photo the bar has to get out of the way: no cream fill, no date repeated (the
        // sheet carries it), and light controls because they sit on the scrim. Everywhere else the
        // bar is unchanged, which is why this is conditional rather than a new default.
        .toolbarBackground(hasFullBleedMedia ? .hidden : .automatic, for: .navigationBar)
        .toolbarColorScheme(hasFullBleedMedia ? .dark : nil, for: .navigationBar)
        // The day it happened, in the bar. The timeline's root hides its bar, so without a title
        // this screen's back chevron and menu float as bare circles on cream — chrome that looks
        // accidental rather than designed. The date is also the one thing worth keeping visible
        // once the metadata row has scrolled away, and it is `occurred_at`, never `created_at`.
        .navigationTitle(navigationTitle)
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
        if entry.unlockAtAge != nil, !unsealed {
            // **Nothing below this branch runs for a sealed entry.** Not the hero, not the sheet,
            // not the prompt, not the transcript. The single gate is the whole seal, and keeping
            // it as one branch rather than a condition repeated per-section is what makes that
            // readable — and what a new section cannot accidentally sit outside of.
            sealedCard(entry)
            noticeLine
        } else {
            VStack(spacing: 0) {
                hero
                sheet(entry)
                noticeLine
            }
        }
    }

    /// Offline, or a fetch that failed over content already on screen. Quiet, and never a dialog.
    @ViewBuilder
    private var noticeLine: some View {
        if let notice {
            Text(notice)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.screenMargin)
                .padding(.top, 16)
        }
    }

    /// Everything that is not the artifact, on one cream surface.
    ///
    /// **One sheet for all six unsealed shapes.** A photo entry and a did-it entry differ in what
    /// is behind this, not in how what is written gets read — which is the design's whole argument
    /// and the reason a no-artifact entry cannot look like a broken one: it is the same finished
    /// surface either way, with a tint behind it instead of a picture.
    private func sheet(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            writtenContent(entry)
            if let prompt = displayPrompt(entry) {
                promptBlock(prompt, on: entry.occurredAt)
                    .padding(.top, 18)
            }
            if let transcript = Self.transcript(in: media) {
                transcriptSection(transcript)
            }
            factsLine(entry)
            tags(entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.screenMargin)
        .padding(.top, 22)
        .padding(.bottom, 28)
        .background(
            Color.surface,
            in: UnevenRoundedRectangle(
                topLeadingRadius: Layout.sheetRadius,
                topTrailingRadius: Layout.sheetRadius,
                style: .continuous
            )
        )
        // Rides up over whatever is behind it, so the sheet reads as resting on the layer rather
        // than sitting beneath it. Only where there is something to overlap.
        .padding(.top, heroIsPresent ? -Layout.sheetOverlap : 0)
    }

    /// What sits behind the sheet — **the one thing that varies across the seven shapes.**
    ///
    /// An enum rather than a `Color`, and a static function rather than a computed property, for
    /// the reason `transcript(in:)` gives two hundred lines up: it is the difference between a
    /// layout decision that can be asserted and one that can only be looked at. The mapping to
    /// paint happens in the view; *which* backdrop an entry gets is a rule, and rules get tests.
    nonisolated enum Backdrop: Equatable {
        /// A picture, running to the screen edges.
        case picture
        /// No artifact — the tint is the picture. Flat, not the export's gradients: neither of
        /// those exists in `Palette`, and `Gradients.wash` is the *sealed* treatment, so reusing
        /// it here or adding two more would give a one-wash system three.
        case voice
        case didIt
        /// A written entry, and the fallback. The sheet is the whole screen.
        case canvas
        /// Sealed. The wash, and nothing behind it to describe.
        case sealed
    }

    /// **Sealed is checked first and returns before anything reads the media.** Ordering is the
    /// safety property here: a sealed letter with a photo must not reach `.picture`, and the only
    /// way to guarantee that structurally is for the seal to answer before the question is asked.
    nonisolated static func backdrop(
        unlockAtAge: Int?,
        unsealed: Bool,
        type: EntryType?,
        pictureCount: Int
    ) -> Backdrop {
        if unlockAtAge != nil, !unsealed { return .sealed }
        if pictureCount > 0 { return .picture }
        switch type {
        case .audio: return .voice
        case .didIt: return .didIt
        default: return .canvas
        }
    }

    private var backdropKind: Backdrop {
        Self.backdrop(
            unlockAtAge: entry?.unlockAtAge,
            unsealed: unsealed,
            type: entry?.type,
            pictureCount: pictures.count
        )
    }

    private var backdrop: Color {
        switch backdropKind {
        case .picture: .ink
        case .voice: .periwinkleSoft
        case .didIt: .sage
        case .canvas, .sealed: .canvas
        }
    }

    /// The one case the navigation bar has to get out of the way for.
    private var hasFullBleedMedia: Bool { backdropKind == .picture }

    /// The date lives in the sheet once a picture is behind the bar, so the bar does not say it
    /// twice over a photograph. Everywhere else it is the one thing worth keeping visible after
    /// the facts line has scrolled away — and it is `occurred_at`, never `created_at`.
    private var navigationTitle: String {
        guard let entry, !hasFullBleedMedia else { return "" }
        return DayHeaderText.compact(entry.occurredAt)
    }

    /// The top block: pictures if there are any, else the voice player, else nothing.
    ///
    /// Nothing is the ordinary case, not the broken one — a written entry and a did-it entry
    /// have no artifact, and the screen opens on the prompt instead.
    @ViewBuilder
    private var hero: some View {
        if !pictures.isEmpty {
            gallery
                // **Edge to edge, and only here.** `design-system.md` says photos "rarely bleed to
                // the screen edge"; this is the rare one — the single screen whose whole job is
                // looking at one artifact. Settled Aug 11, 2026; `decisions.md` rejects a
                // full-bleed *timeline*, which this is not.
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { topScrim }
        } else if let voice = voiceMedia {
            VoicePlayerView(
                mediaId: voice.id,
                durationSeconds: voice.durationSeconds,
                transcript: nil,
                localFile: stagedOriginal(voice),
                api: api
            )
            .padding(.horizontal, Layout.screenMargin)
            .padding(.top, 8)
            .padding(.bottom, Layout.sheetOverlap + 18)
        } else if entry?.type == .didIt {
            // **The did-it hero, and the reason this screen has one at all.** An entry with no
            // artifact is complete, not deficient — so it gets a deliberate mark on a sage ground
            // rather than the empty space where a picture would have been.
            CompletionCheck(isComplete: true, diameter: 64, tint: .sageInk, check: .sage)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .padding(.bottom, Layout.sheetOverlap + 24)
        }
    }

    /// Ink fading to nothing over the top of a photograph, so the bar's controls stay legible on
    /// whatever is behind them. Only over pictures — nothing else puts content under the bar.
    private var topScrim: some View {
        LinearGradient(
            colors: [Color.ink.opacity(0.45), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 132)
        .allowsHitTesting(false)
    }

    /// Whether anything sits behind the sheet's top edge. A written entry has nothing, and its
    /// sheet starts flush rather than overlapping cream with cream.
    private var heroIsPresent: Bool {
        !pictures.isEmpty || voiceMedia != nil || entry?.type == .didIt
    }

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
            // **Still a paged TabView, not the import's thumbnail strip.** The strip is a new
            // control and this is a design pass; paging is what multi-media has done since phase
            // 4 and every existing assertion about it still holds.
            TabView {
                ForEach(pictures, id: \.id) { item in
                    detailMedia(item).padding(.bottom, 30)
                }
            }
            .tabViewStyle(.page)
            .frame(height: galleryHeight)
        }
    }

    /// A full-width 4:3 picture, plus room for the page dots inside the TabView's own frame.
    ///
    /// Derived rather than fixed, because the width is now the screen's: at 393pt a 4:3 picture is
    /// 295pt, and a hardcoded 300 would have cropped it by five points on exactly one device.
    private var galleryHeight: CGFloat {
        UIScreen.main.bounds.width * 3 / 4 + 30
    }

    private func detailMedia(_ item: Media) -> some View {
        DetailMediaView(
            mediaId: item.id,
            kind: item.mediaKind,
            durationSeconds: item.durationSeconds,
            api: api,
            localFile: stagedOriginal(item),
            bleeds: true
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
                // **The check moved to the hero and is not repeated here.** A did-it entry now
                // opens on a 64pt mark over sage; a second one beside the title said the same
                // thing twice on one screen.
                Text(title)
                    .typeRole(.detailTitle)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let body = entry.body, !body.isEmpty {
                Text(body)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.title == nil, media.isEmpty {
                // A did-it entry with no note. Complete, and it says so rather than rendering
                // as a screen with nothing on it. The mark is overhead in the hero; this is the
                // sentence under it.
                Text("We did it")
                    .typeRole(.detailTitle)
                    .foregroundStyle(Color.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The facts, as one sentence rather than a key-and-value list.
    ///
    /// **The import's best idea after the backdrop.** The old list spent five rows and a divider
    /// saying what fits on one line — `[4 years, 1 month]  Sunday 9 August 2026 · 10 photos` — and
    /// a list of keys reads like a form about a memory rather than a caption under one.
    ///
    /// The age keeps its periwinkle capsule: it is the one fact this product is actually about,
    /// and it is the same chip the timeline and the card already use.
    ///
    /// **The sync line is not in here, and that is deliberate.** "Here — it'll sync when you're
    /// back on" is a *state*, not a fact about the entry, and it is the only place this screen
    /// tells a parent their words have not left the phone. Folding it into a metadata sentence
    /// would have been the tidy way to lose it — so it keeps its own line below.
    @ViewBuilder
    private func factsLine(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if let months = entry.childAgeMonths {
                    Text(AgeText.long(months))
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.periwinkle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.periwinkleSoft, in: Capsule())
                }
                Text(factsSentence(entry))
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.sync != .synced {
                // A network fact, not an error and not a loss.
                Text("Here — it'll sync when you're back on")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.top, 22)
    }

    private func factsSentence(_ entry: Entry) -> String {
        Self.factsSentence(for: entry, media: media)
    }

    /// "Sunday 9 August 2026 · 10 photos", or "· 0:42" for a recording.
    ///
    /// The count is only worth saying when there is more than one thing to count, and the length
    /// only when there is something with a length. A single photo says neither, because the
    /// picture is right there.
    ///
    /// **This takes the whole entry, and reads `occurred_at` from it, on purpose.**
    ///
    /// The obvious signature is `(occurredAt: Date, media: [Media])` — and it is worse, because it
    /// moves the choice of field to the caller, where no test can see it. A caller handing over
    /// `entry.createdAt` would satisfy every assertion about this function while filing a
    /// backfilled photograph under the evening it was added. Taking the entry is what makes
    /// "the date is `occurred_at`" a thing that can actually fail.
    nonisolated static func factsSentence(for entry: Entry, media: [Media]) -> String {
        let occurredAt = entry.occurredAt
        let live = media.filter { $0.deletedAt == nil }
        let pictures = live.filter { $0.mediaKind == .photo || $0.mediaKind == .video }
        var parts = [DayHeaderText.full(occurredAt)]
        if pictures.count > 1 {
            parts.append("\(pictures.count) \(Self.picturesLabel(for: pictures).lowercased())")
        }
        if let seconds = live.first(where: { $0.mediaKind == .audio })?.durationSeconds {
            parts.append(DurationText.clock(seconds))
        }
        return parts.joined(separator: " · ")
    }

    /// "Photos", "Videos", or "Items" when the entry holds both. Never "Media", which is a word
    /// for the people who build the app rather than the people who use it.
    private var picturesLabel: String { Self.picturesLabel(for: pictures) }

    nonisolated static func picturesLabel(for pictures: [Media]) -> String {
        if pictures.allSatisfy({ $0.mediaKind == .photo }) { return "Photos" }
        if pictures.allSatisfy({ $0.mediaKind == .video }) { return "Videos" }
        return "Items"
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
    ///
    /// **Unchanged by the v2 pass, on purpose.** The import redraws this as an envelope with a wax
    /// seal and drops **Open it** entirely — its copy reads "it opens on his eighteenth birthday
    /// and not before — not even for you", which is the opposite of what this app decided. The one
    /// thing worth taking from it was the gradient, and `Gradients.wash` already *is* that
    /// gradient: `#FDE8DC → #F7DDE8 → #FBF6EF`, digit for digit. So there was nothing to change,
    /// and every word here is the vocabulary phase 4 settled.
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
        // The screen margin used to come from `content`, which applied one padding to everything.
        // v2 pads per-section instead, because the picture must reach the edge and the sheet must
        // not — so the two states that are still cards carry their own.
        .padding(Layout.screenMargin)
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
