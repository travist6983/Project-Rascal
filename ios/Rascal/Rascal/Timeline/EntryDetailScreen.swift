import SwiftData
import SwiftUI

/// One entry, in full: what was captured, what was asked, what was written, and when.
///
/// It renders from the cache the moment it opens and fetches `GET /entries/{id}` behind that,
/// because the list already holds almost everything this screen needs. What the detail call adds
/// is the two things a list row does not carry — the originating prompt, and the transcripts the
/// phone wrote back — and neither of them is worth a spinner over content that is already here.
///
/// **Three layers, and only the bottom one changes.** A canvas that runs to every edge, floating
/// chrome over it, and a cream sheet resting on the bottom safe area. Seven kinds of entry, one
/// reading surface: what sits behind the sheet is the only thing that varies. That is the whole
/// argument of `docs/entry-detail/project/RASCAL Entry Detail.dc.html`, and the reason a no-artifact
/// entry cannot look like a broken one — it is the same finished surface either way, with a tint
/// behind it instead of a picture.
///
/// **It is presented, never pushed.** See `entryDetail(_:childId:api:openComposer:onDeleted:)`.
struct EntryDetailScreen: View {
    let entryId: UUID
    let childId: UUID
    let api: APIClient
    let openComposer: (ComposerRequest) -> Void
    /// Pop back to the list. Called after a delete, so the row is gone from both screens at once.
    let onDeleted: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The sheet's second state, reached by dragging up from the grabber. Collapsed shows the
    /// title and the meta row; expanded adds the prompt, the chips and the actions.
    @State private var sheetExpanded = false
    /// The photo alone. `[⛶]` dismisses every piece of chrome on the screen, and a tap anywhere
    /// brings it back — the design's own behaviour, which is a chrome toggle over the same
    /// canvas rather than a second screen presented on top of it.
    @State private var immersive = false
    /// Which of several pictures is on the canvas. Drives the counter pill and the strip
    /// together, so paging either one pages the other.
    @State private var pictureIndex = 0
    /// The home indicator's height, measured rather than assumed — the sheet's surface runs
    /// under it while its content clears it, and a hardcoded number is right for one device.
    /// Measured the way `RootView` measures the tab bar, and for the same reason.
    @State private var bottomInset: CGFloat = 0
    /// The sheet's own content height, and the screen's. The sheet hugs its content until that
    /// content outgrows a share of the screen, at which point it scrolls inside itself — see
    /// `sheet(_:)`. Both measured, for the same reason `bottomInset` is.
    @State private var sheetContentHeight: CGFloat = 0
    @State private var screenHeight: CGFloat = 932
    /// The video on the canvas, and the scrubber in the sheet, sharing one position.
    @State private var playback = VideoPlayback()
    @State private var editingTags = false

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
        ZStack {
            // **The backdrop is the layer that changes; the sheet on top of it does not.**
            backdrop.ignoresSafeArea()

            if let entry {
                if backdropKind == .sealed {
                    // **Nothing below this branch runs for a sealed entry.** Not the canvas, not
                    // the sheet, not the prompt, not the transcript. The single gate is the whole
                    // seal, and keeping it as one branch rather than a condition repeated
                    // per-section is what makes that readable — and what a new section cannot
                    // accidentally sit outside of.
                    sealedCard(entry)
                    sealedChrome
                } else {
                    artifact(entry)
                    if immersive {
                        // The way back. A whole-screen target, because the chrome it restores is
                        // the only way off this screen.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { setImmersive(false) }
                            .accessibilityLabel("Show controls")
                    } else {
                        chrome(entry)
                    }
                }
            } else {
                // The row is gone — deleted here or on another phone. Said plainly.
                missing
            }
        }
        .background(Color.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        // **The clock goes away over a photograph, and the app still pins no colour scheme.**
        //
        // Dark status-bar glyphs on a 50% ink scrim do not read, so something had to change. The
        // two candidates were a light status bar — which needs `preferredColorScheme(.dark)`,
        // the only API that actually moves it — or hiding it, which is what `MediaViewerScreen`
        // already does over full-bleed media.
        //
        // Hiding it wins on three counts. `docs/design-system.md` says this app is light only and
        // "pins no scheme", with the widget as its single documented exception; a second one is a
        // precedent, and it would also flip this screen's `Menu` and delete dialog to dark. The
        // design file draws a status bar here, but it draws one on all seven of its screens
        // because all seven are drawn inside a phone frame — that is mockup chrome, not a
        // decision about photographs. And immersive mode already hides it, so the picture canvas
        // now has one behaviour rather than two.
        .statusBarHidden(immersive || backdropKind == .picture)
        .task(id: entryId) { await load() }
        // A player left running behind a dismissed screen keeps the audio session active and
        // the sound playing over whatever the parent opened next.
        .onDisappear { playback.stop() }
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
        .sheet(isPresented: $editingTags) {
            TagEditorSheet(entryId: entryId, api: api)
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

    // MARK: The canvas

    /// What sits behind the sheet — **the one thing that varies across the seven shapes.**
    ///
    /// An enum rather than a `Color`, and a static function rather than a computed property, for
    /// the reason `transcript(in:)` gives further down: it is the difference between a layout
    /// decision that can be asserted and one that can only be looked at. The mapping to paint
    /// happens in the view; *which* backdrop an entry gets is a rule, and rules get tests.
    nonisolated enum Backdrop: Equatable {
        /// A picture, running to every edge.
        case picture
        /// No artifact — the tint is the picture. Flat, not the design file's gradients: neither
        /// of those exists in `Palette`, and `Gradients.wash` is the *sealed* treatment, so
        /// reusing it here or adding two more would give a one-wash system three. See the report.
        case voice
        case didIt
        /// A written entry, and the fallback. The words are the artifact.
        case canvas
        /// Sealed. The wash, and nothing behind it to describe.
        case sealed
    }

    /// **Sealed is checked first and returns before anything reads the media.** Ordering is the
    /// safety property here: a sealed letter with a photo must not reach `.picture`, and the only
    /// way to guarantee that structurally is for the seal to answer before the question is asked.
    ///
    /// **Then media, then completion mode, then the fallback.** A did-it entry someone
    /// photographed is a picture entry: the artifact is what there is to look at, whatever the
    /// server derived the type to be.
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

    /// Where a did-it entry's completion mark goes — **and it goes exactly one place.**
    ///
    /// The did-it canvas puts a 74pt mark on sage when there is no artifact. That is the common
    /// did-it entry and it is the better treatment. But a did-it entry can have a photograph or a
    /// voice note, and then the canvas is taken — so the mark falls back beside the sheet's
    /// heading.
    ///
    /// **Losing it entirely is the bug this enum exists to prevent**, and it is the one the last
    /// pass shipped for a few hours: the canvas stopped drawing the check when a picture was
    /// present and the inline one had already been deleted as a duplicate, so "you did this"
    /// quietly vanished from exactly the did-it entries someone had bothered to photograph.
    nonisolated enum CompletionMark: Equatable {
        case none
        /// Centred on the tint. No artifact competing with it.
        case hero
        /// On the sheet heading's baseline. Something else is using the canvas.
        case inline
    }

    nonisolated static func completionMark(
        type: EntryType?,
        pictureCount: Int,
        hasVoice: Bool
    ) -> CompletionMark {
        guard type == .didIt else { return .none }
        return pictureCount == 0 && !hasVoice ? .hero : .inline
    }

    private var completionMark: CompletionMark {
        Self.completionMark(
            type: entry?.type,
            pictureCount: pictures.count,
            hasVoice: voiceMedia != nil
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

    /// The artifact itself, filling the canvas behind the chrome and the sheet.
    @ViewBuilder
    private func artifact(_ entry: Entry) -> some View {
        switch backdropKind {
        case .picture:
            gallery
        case .voice:
            voiceCanvas
        case .didIt:
            didItCanvas(entry)
        case .canvas:
            writtenCanvas(entry)
        case .sealed:
            EmptyView()
        }
    }

    // MARK: 01 / 02 — pictures

    /// **The picture fills the canvas.** No frame height, no aspect ratio, no container that
    /// refuses to grow: the media is the ground, and `scaledToFill` inside a clipped full-screen
    /// box is what makes "fills the canvas" true for a portrait photograph as well as a square
    /// one. The band this replaced was a 4:3 `aspectRatio` modifier — see the report, D1.
    @ViewBuilder
    private var gallery: some View {
        if pictures.count == 1, let only = pictures.first {
            FullBleedMedia(
                media: only,
                api: api,
                localFile: stagedOriginal(only),
                playback: only.mediaKind == .video ? playback : nil,
                onOpen: { open(only) }
            )
        } else {
            TabView(selection: $pictureIndex) {
                ForEach(Array(pictures.enumerated()), id: \.element.id) { index, item in
                    FullBleedMedia(
                        media: item,
                        api: api,
                        localFile: stagedOriginal(item),
                        playback: nil,
                        onOpen: { open(item) }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
    }

    private func open(_ item: Media) {
        viewing = ViewerRequest(
            id: item.id,
            kind: item.mediaKind,
            localFile: stagedOriginal(item)
        )
    }

    /// Ink fading to nothing over the top of a picture, so the chrome stays legible on whatever
    /// is behind it. Only over pictures — every other canvas is light enough to read dark chrome.
    private var topScrim: some View {
        LinearGradient(
            colors: [Color.ink.opacity(0.5), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: 04 — voice

    /// No picture, so the wash is the picture.
    ///
    /// The player is `VoicePlayerView` in its prominent presentation rather than a second player
    /// written for this screen: the loading, the playback, the elapsed clock and the waveform are
    /// all the same work, and only the size and the ground differ. That is the same call
    /// `DetailMediaView.bleeds` makes, for the same reason.
    @ViewBuilder
    private var voiceCanvas: some View {
        if let voice = voiceMedia {
            VStack {
                Spacer(minLength: 0)
                VoicePlayerView(
                    mediaId: voice.id,
                    durationSeconds: voice.durationSeconds,
                    transcript: nil,
                    localFile: stagedOriginal(voice),
                    api: api,
                    prominent: true
                )
                .padding(.horizontal, 34)
                Spacer(minLength: 0)
                // Clear of the sheet, at whatever height the sheet actually is.
                Color.clear.frame(height: sheetHeight + 24)
            }
        }
    }

    // MARK: 06 — did it

    /// No artifact, so **the prompt is the artifact.**
    ///
    /// It is set at detail-title weight in the middle of the canvas — the same type the written
    /// entry gives its own title — because on this one shape the sentence someone was asked is
    /// the whole of what happened. The line beneath says so in as many words, and it is the one
    /// piece of copy on this screen that exists to stop a complete entry reading as a deficient
    /// one.
    @ViewBuilder
    private func didItCanvas(_ entry: Entry) -> some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            CompletionCheck(isComplete: true, diameter: 74, tint: .surface, check: .sageInk)
            if let prompt = displayPrompt(entry) {
                Text(prompt)
                    .typeRole(.detailTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing was recorded. That's allowed — it still happened.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Color.clear.frame(height: sheetHeight + 24)
        }
        .padding(.horizontal, 30)
    }

    // MARK: 05 — written

    /// The words are the media, on cream, with no glass anywhere.
    ///
    /// It scrolls, because a long entry is the ordinary case and the design's fixed reading box
    /// would clip one. The question sits above the title in a periwinkle callout — periwinkle is
    /// questions and written entries both, which is why this is the one canvas where the tint
    /// and the type agree.
    private func writtenCanvas(_ entry: Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let prompt = displayPrompt(entry) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The question")
                            .typeRole(.label)
                            .foregroundStyle(Color.periwinkle)
                        Text(prompt)
                            .typeRole(.body)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .background(
                        Color.periwinkleSoft,
                        in: RoundedRectangle(cornerRadius: Layout.quoteBlockRadius, style: .continuous)
                    )
                    .padding(.bottom, 26)
                }
                if let title = entry.title, !title.isEmpty {
                    Text(title)
                        .typeRole(.detailTitle)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 16)
                }
                if let body = entry.body, !body.isEmpty {
                    Text(body)
                        .typeRole(.body)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.screenMargin + 4)
            // Clear of the chrome above and the footer below. **The footer's real height** —
            // it is drawn over this scroll view, so a fixed inset leaves the end of a long entry
            // permanently underneath it.
            .padding(.top, 74)
            .padding(.bottom, sheetHeight + 24)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Chrome

    /// Back, the counter, and the overflow — floating over whatever the canvas is.
    ///
    /// **Translucent and neutral, with no accent ring.** A terracotta stroke here made two
    /// ordinary controls look like the primary action on a screen whose primary action is
    /// looking at a photograph. Terracotta is missions and primary action; a back button is
    /// neither.
    @ViewBuilder
    private func chrome(_ entry: Entry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                chromeButton(
                    system: "chevron.left",
                    label: "Back",
                    weight: .semibold
                ) { dismiss() }

                Spacer(minLength: 0)

                if pictures.count > 1 {
                    Text("\(pictureIndex + 1) of \(pictures.count)")
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.surface)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(Color.ink.opacity(0.42), in: Capsule())
                        .accessibilityLabel("Picture \(pictureIndex + 1) of \(pictures.count)")
                    Spacer(minLength: 0)
                }

                // **One photograph only.** With several, paging is what the canvas is for and a
                // fullscreen control competes with it; with none there is nothing to expand; and
                // on a video the centre play control already owns the canvas, so a second
                // affordance over the same frame is two controls asking for the same tap.
                if isSinglePhoto {
                    chromeButton(
                        system: "arrow.down.left.and.arrow.up.right",
                        label: "Hide the controls"
                    ) { setImmersive(true) }
                }

                overflowButton
            }
            .padding(.horizontal, Layout.Chrome.inset)
            .padding(.top, 10)

            Spacer(minLength: 0)

            sheet(entry)
        }
        .background(alignment: .top) {
            if backdropKind == .picture { topScrim }
        }
    }

    private func chromeButton(
        system: String,
        label: String,
        weight: Font.Weight = .medium,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: weight))
                .foregroundStyle(Color.ink)
                .frame(width: Layout.Chrome.diameter, height: Layout.Chrome.diameter)
                .background(Color.surface.opacity(0.9), in: Circle())
                .shadow(color: .ink.opacity(0.18), radius: 5, y: 2)
                // The drawn circle is 40; the target is 44, which is the floor.
                .frame(width: Layout.Chrome.tapTarget, height: Layout.Chrome.tapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel(label)
    }

    private var overflowButton: some View {
        Menu {
            Button { edit() } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: Layout.Chrome.diameter, height: Layout.Chrome.diameter)
                .background(Color.surface.opacity(0.9), in: Circle())
                .shadow(color: .ink.opacity(0.18), radius: 5, y: 2)
                .frame(width: Layout.Chrome.tapTarget, height: Layout.Chrome.tapTarget)
                .contentShape(Circle())
        }
        .disabled(entry == nil)
        .accessibilityLabel("Entry options")
    }

    private func setImmersive(_ value: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.cardToDone) {
            immersive = value
        }
    }

    // MARK: The sheet

    /// Everything that is not the artifact, on one cream surface anchored to the bottom.
    ///
    /// **One sheet for all six unsealed shapes**, and it is a real bottom-anchored surface rather
    /// than the last child of a scrolling stack. That is the correction: the sheet used to be a
    /// `VStack` member inside a `ScrollView`, so on any entry whose content was shorter than the
    /// screen it floated wherever the stack ended and left the canvas showing beneath it. It now
    /// sits on the bottom safe area, rounded on the top corners only, with a grabber over it.
    private func sheet(_ entry: Entry) -> some View {
        // **The content scrolls once it outgrows its cap, and the cap is a share of the screen
        // rather than a number.** At the accessibility sizes an expanded sheet carrying a
        // caption, a prompt and a chip row is taller than the phone, and a `VStack` that simply
        // hugs its content pushes the title up past the top edge — where a fixed height would
        // have clipped it instead. Neither is acceptable, so it scrolls inside itself and the
        // canvas keeps whatever is left. `.basedOnSize` means a short sheet still does not
        // bounce, so nothing about the ordinary case changes.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                grabber
                strip
                collapsedContent(entry)
                if sheetExpanded, sheetExpands { expandedContent(entry) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetContentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: sheetHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, sheetHasEdgeToEdgeContent ? 0 : 20)
        .padding(.top, 12)
        // **Content clears the home indicator; the surface runs under it.** The safe-area inset
        // is added as padding and the background then ignores the safe area, so the sheet reads
        // as resting on the bottom edge of the screen rather than floating a strip of canvas
        // above it — which is what it did when the whole thing simply respected the inset.
        .padding(.bottom, bottomInset + 12)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: sheetIsFlush ? 0 : Layout.sheetRadius,
                topTrailingRadius: sheetIsFlush ? 0 : Layout.sheetRadius,
                style: .continuous
            )
            .fill(sheetGround)
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            // A written entry's footer is flush with its own cream canvas, so a hairline is the
            // only thing that separates the two. Every other sheet is a different surface from
            // what is behind it and needs none.
            //
            // **And the body scrolls underneath it, so the hairline alone is not enough.** A long
            // entry met that line and was cut off mid-word, which reads as a rendering fault
            // rather than as more text below. `PinnedActionBackdrop` with 26 above it is the
            // pattern this app already uses everywhere content scrolls under something pinned.
            if sheetIsFlush {
                VStack(spacing: 0) {
                    PinnedActionBackdrop()
                        .frame(height: 26)
                        .offset(y: -26)
                    Rectangle().fill(Color.border).frame(height: Layout.borderWidth)
                }
                .allowsHitTesting(false)
            }
        }
        .shadow(color: .ink.opacity(sheetIsFlush ? 0 : 0.20), radius: 17, y: -8)
        .contentShape(Rectangle())
        .gesture(sheetDrag)
        .accessibilityElement(children: .contain)
    }

    /// A written entry's sheet is the bottom of the same cream page, not a surface over another
    /// one — so it takes no corner radius, no shadow and no glass, and the hairline does the
    /// separating. The design file draws exactly this and it is the only shape that gets it.
    private var sheetIsFlush: Bool { backdropKind == .canvas }

    /// The thumbnail strip bleeds to both edges, so the sheet's own horizontal padding comes off
    /// and every other row puts it back.
    private var sheetHasEdgeToEdgeContent: Bool { pictures.count > 1 }

    private var sheetGround: Color { sheetIsFlush ? .canvas : .surface }

    /// What the sheet actually occupies, so the canvas behind it can keep clear of it.
    ///
    /// **Measured, never assumed.** The clearances here were 200, 170 and 40 — three numbers
    /// tuned to one text size, which at the accessibility sizes put the waveform and the last
    /// line of a written entry behind a sheet that had grown past them. The sheet reports its own
    /// height for the same reason `FloatingTabBar` reports its own to `RootView`.
    private var sheetHeight: CGFloat {
        min(sheetContentHeight, screenHeight * Self.sheetHeightShare)
    }

    /// How much of the screen the sheet may take before it scrolls inside itself.
    private static let sheetHeightShare: CGFloat = 0.72


    /// **Only where there is somewhere to drag to.** A grabber over a sheet with one state is
    /// the same lie as a chevron on a row that does not navigate.
    @ViewBuilder
    private var grabber: some View {
        if !sheetIsFlush, sheetExpands {
            Capsule()
                .fill(Color.border)
                .frame(width: Layout.Grabber.width, height: Layout.Grabber.height)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Layout.Grabber.clearance)
                .accessibilityHidden(true)
        }
    }

    /// The thumbnail strip, above the title, on an entry holding more than one picture.
    ///
    /// **Paging is bidirectional because both ends read the same `pictureIndex`** — tapping a
    /// tile pages the canvas, swiping the canvas scrolls the strip to the tile. One piece of
    /// state, so the two cannot disagree about which picture is showing.
    ///
    /// **Every tile lays out as its tinted placeholder when there is no picture**, which is the
    /// ordinary case rather than the error case: `thumb_key` is null on every media row the
    /// server has ever returned, so a strip of ten placeholders is what a freshly synced entry
    /// looks like on a second device. No grey box, no broken-image glyph, no reserved gap.
    @ViewBuilder
    private var strip: some View {
        if pictures.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(pictures.enumerated()), id: \.element.id) { index, item in
                            Button {
                                withAnimation(reduceMotion ? nil : Motion.cardToDone) {
                                    pictureIndex = index
                                }
                            } label: {
                                StripTile(media: item, isCurrent: index == pictureIndex)
                            }
                            .buttonStyle(TapScaleButtonStyle())
                            .id(index)
                            .accessibilityLabel("Picture \(index + 1)")
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .onChange(of: pictureIndex) { _, index in
                    withAnimation(reduceMotion ? nil : Motion.cardToDone) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// Drag up to expand, down to collapse — and a tap does the same thing, because a grabber
    /// that only answers to a drag is invisible to anyone using Switch Control.
    private var sheetDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard sheetExpands, abs(value.translation.height) > 24 else { return }
                setExpanded(value.translation.height < 0)
            }
    }

    private func setExpanded(_ value: Bool) {
        guard value != sheetExpanded else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.cardToDone) {
            sheetExpanded = value
        }
    }

    /// Title, the parent's own words where there are any, then the one meta row.
    ///
    /// **Every zone drops out when it is empty** — the rule `EntryCard` already holds. No
    /// reserved space, no placeholder frame, no gap where a caption would go. Half the mission
    /// library produces no artifact and plenty of entries carry no note, so a sheet with nothing
    /// but a title and a date is the common case and has to look deliberate.
    @ViewBuilder
    private func collapsedContent(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // **In the sheet, not over the picture** — the design's whole reason for putting it
            // here. Only for a single video, which is the only shape with a position to report.
            if isSingleVideo, playback.duration > 0 {
                EntryScrubber(
                    elapsed: playback.elapsed,
                    duration: playback.duration,
                    onScrub: { playback.scrub(toFraction: $0) },
                    onCommit: { Task { await playback.endScrub() } }
                )
                .padding(.bottom, 18)
            }
            if let heading = sheetHeading(entry) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Only when the canvas is not already carrying it — see `completionMark`. A
                    // did-it entry with a photograph has a taken canvas, so the mark comes back
                    // here rather than disappearing.
                    if completionMark == .inline {
                        CompletionCheck(isComplete: true, diameter: 22, tint: .sageInk, check: .sage)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    }
                    Text(heading)
                        .typeRole(.cardTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let caption = sheetCaption(entry) {
                Text(caption)
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if let transcript = Self.transcript(in: media) {
                // The words are the artifact on a voice entry, so they are in the sheet at
                // reading strength rather than under a label further down. `PATCH
                // /media/{id}/derived` made them permanent; the phone never regenerates them.
                Text("“\(transcript)”")
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .lineLimit(sheetExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: sheetExpanded)
                    .padding(.top, 10)
                if !sheetExpanded {
                    Text("Read the whole thing")
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.periwinkle)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isButton)
                        .onTapGesture { setExpanded(true) }
                }
            }
            metaRow(entry).padding(.top, 12)
            // **On the two shapes whose sheet does not open, the chips are already here.** A
            // written entry's footer and a did-it entry's sheet have no second state to drag to
            // — the artifact is the canvas and there is nothing else to reveal — so hiding the
            // kind and the tags behind a gesture that leads nowhere would simply lose them.
            if chipsRestVisible { chips(entry).padding(.top, 14) }
        }
        .padding(.horizontal, sheetHasEdgeToEdgeContent ? 20 : 0)
    }

    /// Whether the sheet has a second state at all. A written entry's footer is flush and does
    /// not drag; a did-it entry has nothing further to say.
    private var sheetExpands: Bool { !chipsRestVisible }

    private var chipsRestVisible: Bool {
        backdropKind == .canvas || backdropKind == .didIt
    }

    /// The line at the top of the sheet, and **never a line the canvas has already set.**
    ///
    /// A written entry's title and a did-it entry's prompt are both the artifact, out on the
    /// canvas at detail-title size — repeating either one in the sheet a thumb's width below it
    /// is the screen saying the same sentence twice. So written contributes no heading at all,
    /// and did-it contributes the parent's note instead.
    ///
    /// A did-it entry with neither still says the one thing there is to say rather than opening
    /// on a blank surface.
    private func sheetHeading(_ entry: Entry) -> String? {
        switch backdropKind {
        case .canvas:
            return nil
        case .didIt:
            if let body = entry.body, !body.isEmpty { return body }
            return nil
        default:
            if let title = entry.title, !title.isEmpty { return title }
            if entry.type == .didIt { return "We did it" }
            return nil
        }
    }

    /// The parent's own words under the title. Never on a did-it entry, whose note is already the
    /// heading, and never on a written entry, whose body is the artifact on the canvas.
    private func sheetCaption(_ entry: Entry) -> String? {
        guard backdropKind != .didIt, backdropKind != .canvas else { return nil }
        guard let body = entry.body, !body.isEmpty else { return nil }
        return body
    }

    /// The age, then the date. One line, not a key-and-value list.
    ///
    /// **The import's best idea after the backdrop.** The old block spent five rows and a divider
    /// saying what fits on one line, and a list of keys reads like a form about a memory rather
    /// than a caption under one.
    ///
    /// The age keeps its periwinkle capsule: it is the one fact this product is actually about,
    /// and it is the same chip the timeline and the card already use.
    @ViewBuilder
    private func metaRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if let months = entry.childAgeMonths {
                    Text(AgeText.long(months))
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.periwinkle)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(Color.periwinkleSoft, in: Capsule())
                }
                Text(factsSentence(entry))
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.sync != .synced {
                // **A network fact, not an error and not a loss.** It keeps its own line rather
                // than being folded into the sentence above: it is a *state*, not a fact about
                // the entry, and it is the only place this screen tells a parent their words
                // have not left the phone.
                Text("Here — it'll sync when you're back on")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What the drag reveals: the kind chip, the tags, and — where the canvas has not already
    /// shown it — the prompt that started this.
    @ViewBuilder
    private func expandedContent(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Not on written or did-it: both of those already carry the prompt on the canvas,
            // and printing it twice on one screen is the sheet repeating the artifact.
            if backdropKind != .canvas, backdropKind != .didIt,
               let prompt = displayPrompt(entry) {
                Rectangle()
                    .fill(Color.border)
                    .frame(height: Layout.borderWidth)
                    .padding(.vertical, 16)
                Text("The prompt")
                    .typeRole(.label)
                    .foregroundStyle(Color.inkMuted)
                    .accessibilityAddTraits(.isHeader)
                Text(prompt)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            chips(entry).padding(.top, 16)
        }
        .padding(.horizontal, sheetHasEdgeToEdgeContent ? 20 : 0)
        .transition(.opacity)
    }

    /// The kind, then the tags. **No "Add tag".**
    ///
    /// The design file draws one, and this build has no tag editor to open — tags are read-only
    /// in this phase, which is why `Entry.storedTagNames` is a denormalised copy rather than a
    /// relationship. A chip that opens nothing is a control that lies, and building the editor
    /// behind it is a feature rather than a fidelity correction. Reported rather than faked.
    @ViewBuilder
    private func chips(_ entry: Entry) -> some View {
        let tags = entry.tagNames
        if kindChip != nil || !tags.isEmpty {
            // **Every tag, not the card's two.** `EntryCard` caps at two because a third pushes
            // the row past the card on a narrow phone; this sheet wraps and has the room, and
            // `docs/design-system.md` puts no cap on Entry Detail's tags. Truncating the archive's
            // own vocabulary on the one screen with space for it would be a regression.
            FlowRow(spacing: 8) {
                if let kind = kindChip {
                    Chip(text: kind.name, foreground: kind.ink, background: kind.fill, emphasis: true)
                }
                ForEach(tags, id: \.self) { tag in
                    Chip(text: tag, background: .chipPlain, emphasis: true)
                }
                addTagChip
            }
        }
    }

    /// **Add tag**, and it opens a real editor.
    ///
    /// Dashed rather than filled, because it is an invitation rather than a label — the one chip
    /// in the row that is a control. The design file draws it in `#D9CFC0` over `#A8A096`, and
    /// neither is a palette colour: the dash takes `border` and the ink takes `inkMuted` rather
    /// than `inkFaint`, which measures 2.13:1 on cream and is under the 3:1 floor for anything
    /// that is not decorative. Reported rather than added as two new tokens.
    private var addTagChip: some View {
        Button { editingTags = true } label: {
            Text("Add tag")
                .typeRole(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .overlay(
                    Capsule().strokeBorder(
                        Color.border,
                        style: StrokeStyle(lineWidth: Layout.borderWidth, dash: [4, 3])
                    )
                )
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel("Add a tag")
    }

    /// Name, fill and ink for the kind chip — the pairing `EntryCard` already uses, so the two
    /// surfaces stay one vocabulary. An entry type this build does not recognise gets no chip
    /// rather than a guessed tint.
    private var kindChip: (name: String, fill: Color, ink: Color)? {
        switch entry?.type {
        case .photo: ("Photo", .terracottaSoft, .terracottaDeep)
        case .video: ("Video", .terracottaSoft, .terracottaDeep)
        case .audio: ("Voice", .periwinkleSoft, .periwinkle)
        case .text: ("Written", .periwinkleSoft, .periwinkle)
        case .didIt: ("Did it", .sage, .sageInk)
        default: nil
        }
    }

    // MARK: Facts

    private func factsSentence(_ entry: Entry) -> String {
        Self.factsSentence(for: entry, media: media)
    }

    /// "Monday 10 August 2026, 10:04am", or "Sunday 9 August 2026 · 10 photos".
    ///
    /// **One qualifier at most, and the time is what it falls back to.** A count or a length is
    /// the more useful thing to say about an entry that has one, and the design file prints
    /// exactly one of the three on every shape it draws. A single photo says neither a count nor
    /// a length — the picture is right there and it has no duration — so it says the time
    /// instead, which is the fact left over.
    ///
    /// A did-it entry says neither. It has no artifact to measure and its moment is usually an
    /// evening rather than an instant; the design prints the day alone, and stating 6:00pm for
    /// "let him choose dinner" would be a precision nobody recorded.
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
        var parts: [String] = []
        if pictures.count > 1 {
            parts.append("\(pictures.count) \(Self.picturesLabel(for: pictures).lowercased())")
        }
        // Audio first, then video: an entry holding both is a voice note over a clip, and the
        // recording is the thing with a length worth stating.
        if let seconds = live.first(where: { $0.mediaKind == .audio })?.durationSeconds
            ?? live.first(where: { $0.mediaKind == .video })?.durationSeconds {
            parts.append(DurationText.clock(seconds))
        }
        guard parts.isEmpty else {
            return ([DayHeaderText.entryDate(occurredAt)] + parts).joined(separator: " · ")
        }
        guard entry.type != .didIt else { return DayHeaderText.entryDate(occurredAt) }
        return DayHeaderText.entryDateAndTime(occurredAt)
    }

    /// "Photos", "Videos", or "Items" when the entry holds both. Never "Media", which is a word
    /// for the people who build the app rather than the people who use it.
    nonisolated static func picturesLabel(for pictures: [Media]) -> String {
        if pictures.allSatisfy({ $0.mediaKind == .photo }) { return "Photos" }
        if pictures.allSatisfy({ $0.mediaKind == .video }) { return "Videos" }
        return "Items"
    }

    // MARK: Content

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

    /// Photos and video. Audio is not here — it gets the canvas to itself.
    private var pictures: [Media] {
        media.filter { $0.mediaKind == .photo || $0.mediaKind == .video }
    }

    private var voiceMedia: Media? {
        media.first { $0.mediaKind == .audio }
    }

    /// Exactly one picture, and it is a photograph. The only shape that offers `[⛶]`.
    private var isSinglePhoto: Bool {
        pictures.count == 1 && pictures.first?.mediaKind == .photo
    }

    /// Exactly one picture, and it is a video. The only shape with a scrubber.
    private var isSingleVideo: Bool {
        pictures.count == 1 && pictures.first?.mediaKind == .video
    }

    /// The words to set in the sheet, or nothing at all.
    ///
    /// A static rule rather than a branch inside the view, for the same reason `factsSentence` is
    /// one: it is the difference between a layout decision that can be asserted and one that can
    /// only be looked at. **The absence case is the one worth guarding** — an audio entry with no
    /// transcript is a complete entry, not a deficient one, and this screen must render it
    /// exactly as it did before transcription existed: no heading, no empty block, no
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

    // MARK: Sealed

    /// Calm and deliberate. It says what it is, when it opens, and that the parent may open it
    /// anyway — because they wrote it, and a lock the author cannot pick is a lock on the wrong
    /// person.
    ///
    /// **Unchanged by this pass, on purpose.** The design file redraws this as an envelope with a
    /// wax seal and drops **Open it** entirely — its copy reads "it opens on his eighteenth
    /// birthday and not before — not even for you", which is the opposite of what this app
    /// decided. `docs/decisions.md` settled it, and the sealed reader is out of scope here.
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
            Text("Written on \(DayHeaderText.entryDate(entry.occurredAt)), and waiting.")
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
        .padding(Layout.screenMargin)
        // **Kept at the top of the screen, where it has always been.** `docs/decisions.md` settles
        // the sealed reader and this pass does not touch it — but the navigation bar it used to
        // sit under is gone, so without this it would centre itself in the space that bar was
        // holding, which is a change to a settled screen made by accident.
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, Layout.Chrome.tapTarget + 18)
    }

    /// Back and the overflow, over a sealed letter.
    ///
    /// **Separate from `sealedCard` and positioned against the screen**, not against the card:
    /// an overlay on the card puts these two buttons on the card's own top edge, floating in the
    /// middle of the screen.
    ///
    /// It carries the overflow, not just the way back. Moving this screen off the navigation bar
    /// took Edit and Delete with it, and a sealed letter is the one entry a parent most needs to
    /// be able to delete — it is the one they cannot open to check.
    private var sealedChrome: some View {
        VStack(spacing: 0) {
            HStack {
                chromeButton(system: "chevron.left", label: "Back", weight: .semibold) { dismiss() }
                Spacer(minLength: 0)
                overflowButton
            }
            .padding(.horizontal, Layout.Chrome.inset)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
    }

    /// Nothing to render: no cached row, and the fetch did not produce one.
    ///
    /// **Two different things, and they must not read the same.** A 404 means the entry is gone
    /// and saying so is the truth. A phone with no network and nothing cached means the entry is
    /// almost certainly fine and this device simply cannot see it — and telling that parent their
    /// entry was deleted is the archive claiming a loss that has not happened. `notice` carries
    /// what actually went wrong, and it is the difference between the two sentences.
    private var missing: some View {
        VStack(spacing: 10) {
            Text(notice == nil ? "That's no longer here" : "Can't open this one")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text(notice ?? "This entry was deleted.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back") { dismiss() }
                .typeRole(.cardTitle)
                .foregroundStyle(Color.terracotta)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(Layout.screenMargin)
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

/// A picture filling the canvas, with a play control over it when it is a video.
///
/// **Its own view rather than a third mode on `DetailMediaView`.** That view is an inset card
/// with a fixed 4:3 box, a hairline and a corner radius, and every one of those is wrong here —
/// what is left after removing them is a different view, not a parameter.
private struct FullBleedMedia: View {
    let media: Media
    let api: APIClient
    let localFile: URL?
    /// Set only for a single video. Nil everywhere else, and nil is what keeps a ten-photo entry
    /// from standing up a player it will never use.
    let playback: VideoPlayback?
    let onOpen: () -> Void

    @Environment(\.thumbnails) private var thumbnails
    @State private var poster: PlatformImage?
    private let staging = StagingStore()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The ground under a picture that has not arrived, and the whole picture for a
                // row whose bytes are still in storage. **Not a grey box and not a broken-image
                // glyph** — `thumb_key` is null on every row the server has ever returned, so a
                // tile with no picture is the ordinary case rather than the error case.
                Color.ink
                #if canImport(UIKit)
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                #endif
                // The frames, once there is a player. It sits over the poster rather than
                // replacing it, so the first frame does not flash cream on the way in.
                if let player = playback?.currentPlayer {
                    VideoSurface(player: player)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                }
                if media.mediaKind == .video, let playback {
                    // **It plays here.** The scrubber is in the sheet and the picture is never
                    // covered by chrome, which only works if the picture stays where it is.
                    // Hidden while playing, so a running video is a running video rather than a
                    // picture with a button on it; a tap anywhere brings the control back.
                    if !playback.isPlaying {
                        Button {
                            Task { await playback.toggle(mediaId: media.id, localFile: localFile, api: api) }
                        } label: {
                            Group {
                                if playback.loading {
                                    ProgressView().tint(.terracotta)
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 26, weight: .semibold))
                                        .foregroundStyle(Color.terracotta)
                                }
                            }
                            .frame(width: 76, height: 76)
                            .background(Color.surface.opacity(0.92), in: Circle())
                            .shadow(color: .ink.opacity(0.28), radius: 12, y: 6)
                        }
                        .buttonStyle(TapScaleButtonStyle())
                        .accessibilityLabel(videoLabel)
                    }
                    if let notice = playback.notice {
                        Text(notice)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.surface)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.ink.opacity(0.55), in: Capsule())
                            .offset(y: 62)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            guard media.mediaKind == .video else { return onOpen() }
            // Pause a running video; a paused one is left alone so the tap that revealed the
            // control does not also restart it.
            if let playback, playback.isPlaying {
                Task { await playback.toggle(mediaId: media.id, localFile: localFile, api: api) }
            }
        }
        .task(id: media.id) {
            playback?.prime(durationSeconds: media.durationSeconds)
            await loadPoster()
        }
        .accessibilityLabel(media.mediaKind == .video ? videoLabel : "Photo, tap to open")
    }

    private var videoLabel: String {
        guard let seconds = media.durationSeconds else { return "Video, tap to play" }
        return "Video, \(DurationText.spoken(seconds)), tap to play"
    }

    private func loadPoster() async {
        #if canImport(UIKit)
        if let cached = await thumbnails?.image(for: media.id, kind: media.mediaKind) {
            poster = cached
            return
        }
        guard media.mediaKind == .video else { return }
        guard let data = await MediaAccess.posterFrame(
            mediaId: media.id, localFile: localFile, api: api, staging: staging
        ) else { return }
        poster = UIImage(data: data)
        #endif
    }
}

/// One tile in the sheet's thumbnail strip.
///
/// The current one takes a 2pt terracotta ring. **The ring rather than a size change or an
/// opacity drop**: the strip is small enough that a tile which shrinks reads as a rendering
/// fault, and a dimmed one reads as unavailable rather than as not-current.
private struct StripTile: View {
    let media: Media
    let isCurrent: Bool

    @Environment(\.thumbnails) private var thumbnails
    @State private var image: PlatformImage?

    private let side: CGFloat = 56

    var body: some View {
        ZStack {
            // The placeholder, and on most rows the whole tile — see `strip`.
            Color.chipPlain
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: media.mediaKind == .video ? "video" : "camera")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.inkMuted)
            }
            #endif
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isCurrent ? Color.terracotta : .clear, lineWidth: 2)
        }
        .task(id: media.id) {
            #if canImport(UIKit)
            image = await thumbnails?.image(for: media.id, kind: media.mediaKind)
            #endif
        }
    }
}

/// What the fullscreen cover needs. `Identifiable` so it can drive `fullScreenCover(item:)`,
/// which is the presentation that cannot get out of step with its content.
struct ViewerRequest: Identifiable, Equatable {
    let id: UUID
    let kind: PromptKind
    let localFile: URL?
}
