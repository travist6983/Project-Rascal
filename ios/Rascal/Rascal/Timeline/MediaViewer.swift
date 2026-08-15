import AVKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// One picture or video, large, inset from the edge with rounded corners.
///
/// Photos rarely bleed to the screen edge — `docs/design-system.md`, layout rules. The inset is
/// not decoration: a full-bleed photo card is on the rejected list, and the same instinct applies
/// one screen deeper.
struct DetailMediaView: View {
    let mediaId: UUID
    let kind: PromptKind
    let durationSeconds: Int?
    /// Needed only to generate a poster for a video this phone did not record. Nil elsewhere,
    /// and the view degrades to its tinted placeholder.
    var api: APIClient?
    var localFile: URL?
    /// Entry Detail's v2 hero runs the picture to the screen edges: no radius, no hairline.
    ///
    /// **A parameter rather than a second view.** The loading, the poster generation, the video
    /// runtime and the accessibility label are all the same work, and the only thing that differs
    /// is the shape — which is exactly the case where forking costs two of everything and buys
    /// nothing. Defaults to the inset card, so nothing that existed changes.
    var bleeds: Bool = false
    let onOpen: () -> Void

    @Environment(\.thumbnails) private var thumbnails
    @State private var poster: PlatformImage?
    private let staging = StagingStore()

    var body: some View {
        Button(action: onOpen) {
            // **The picture is an overlay, not a stack child, and that is load bearing.**
            // At `scaledToFill` the image is deliberately larger than the box it sits in, and a
            // `ZStack` sizes itself to its children — so the photo decided the layout and bled
            // to the screen edge, straight past the inset the design system asks for. It only
            // shows on media that is not 4:3: a 16:9 video, or any portrait photograph, which
            // is to say most of them.
            Color.terracottaSoft
                .frame(maxWidth: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { picture }
                .overlay { if kind == .video { playGlyph } }
                // The hero radius, not the general media inset: this is the largest shape on
                // Entry Detail and v3 softens it a step past a card. Squared off entirely when it
                // bleeds — a rounded corner against the screen edge reads as a rendering fault.
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: bleeds ? 0 : Layout.heroRadius, style: .continuous
                    )
                )
                // The hairline is what separates an inset card from the cream behind it. A picture
                // that reaches the screen edge has nothing to be separated from.
                .overlay {
                    if !bleeds {
                        RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous)
                            .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                    }
                }
                .overlay(alignment: .bottomTrailing) { runtime }
                .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .task(id: mediaId) { await loadPoster() }
        .accessibilityLabel(accessibilityLabel)
    }

    /// How long the video runs, before anyone commits to watching it.
    @ViewBuilder
    private var runtime: some View {
        if kind == .video, let durationSeconds {
            Text(DurationText.clock(durationSeconds))
                .typeRole(.metadata)
                .foregroundStyle(Color.surface)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.ink.opacity(0.55), in: Capsule())
                .padding(10)
        }
    }

    private var accessibilityLabel: String {
        guard kind == .video else { return "Photo, tap to open" }
        guard let durationSeconds else { return "Video, tap to play" }
        return "Video, \(DurationText.spoken(durationSeconds)), tap to play"
    }

    @ViewBuilder
    private var picture: some View {
        #if canImport(UIKit)
        if let poster {
            Image(uiImage: poster)
                .resizable()
                .scaledToFill()
        }
        #endif
    }

    /// The cache first, then — for a video with nothing cached — one generated frame.
    private func loadPoster() async {
        #if canImport(UIKit)
        if let cached = await thumbnails?.image(for: mediaId, kind: kind) {
            poster = cached
            return
        }
        guard kind == .video, let api else { return }
        guard let data = await MediaAccess.posterFrame(
            mediaId: mediaId, localFile: localFile, api: api, staging: staging
        ) else { return }
        poster = UIImage(data: data)
        #endif
    }

    /// A poster frame at 400px stretched across a phone is soft, and the play glyph is what
    /// tells you it is a video rather than a bad photo.
    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color.surface)
            .frame(width: 58, height: 58)
            .background(Color.ink.opacity(0.42), in: Circle())
    }
}

/// Fullscreen. Photos pinch to zoom, videos play.
///
/// Deliberately its own presentation rather than a zoom inside the scroll view: a photo someone
/// wants to look at properly should not be competing with a scroll gesture, and a video should
/// own the screen while it plays.
struct MediaViewerScreen: View {
    /// Every picture in the entry, in the order the screen showed them.
    let items: [ViewerItem]
    let startIndex: Int
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @State private var current: UUID
    /// How far the sheet has been dragged down. Drives both the offset and the fade, so the
    /// gesture shows its own progress rather than being all-or-nothing at the threshold.
    @GestureState private var drag: CGFloat = 0

    init(items: [ViewerItem], startIndex: Int, api: APIClient) {
        self.items = items
        self.startIndex = startIndex
        self.api = api
        _current = State(initialValue: items.indices.contains(startIndex) ? items[startIndex].id : (items.first?.id ?? UUID()))
    }

    /// Past this, letting go closes it. Short enough to feel like a flick and long enough that a
    /// sloppy pan while looking at a photo does not dismiss the thing being looked at.
    private static let dismissThreshold: CGFloat = 120

    var body: some View {
        ZStack {
            // Not pure black even here. The palette has no #000, and a dark warm ground reads
            // better against cream photos than a void does.
            Color.ink.ignoresSafeArea()

            // **A page per picture.** The viewer used to take one id, so seeing the next photo in
            // an entry meant closing this and tapping again — on a screen whose whole purpose is
            // looking at a set. Each page owns its own load and its own zoom, so paging away from
            // a photo does not carry its magnification onto the next one.
            TabView(selection: $current) {
                ForEach(items) { item in
                    ViewerPage(item: item, api: api).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.surface)
                            .frame(width: 36, height: 36)
                            .background(Color.ink.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
            .padding(Layout.screenMargin)
        }
        .offset(y: drag)
        // Fades toward the timeline underneath as it goes, so the gesture reads as putting the
        // photo down rather than as the screen glitching.
        .opacity(1 - min(drag / (Self.dismissThreshold * 2.5), 0.5))
        .gesture(
            // **Vertical only, and downward only.** A horizontal drag belongs to the pager, and
            // an upward one means nothing here — claiming either would make paging feel sticky.
            DragGesture(minimumDistance: 12)
                .updating($drag) { value, state, _ in
                    guard value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width)
                    else { return }
                    state = value.translation.height
                }
                .onEnded { value in
                    guard value.translation.height > Self.dismissThreshold,
                          abs(value.translation.height) > abs(value.translation.width)
                    else { return }
                    dismiss()
                }
        )
        .animation(Motion.tap, value: drag)
        .statusBarHidden()
    }

}

/// One picture in the viewer's pager.
///
/// **A view of its own so each page owns its load and its zoom.** Held on the container, a single
/// `zoom` would follow the parent's finger onto the next photograph, and a single `image` would
/// mean every page rendering whichever one resolved last. It also means a page that fails is one
/// page that failed, not the viewer.
private struct ViewerPage: View {
    let item: ViewerItem
    let api: APIClient

    @State private var image: PlatformImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var kind: PromptKind { item.kind }
    private var mediaId: UUID { item.id }
    private var localFile: URL? { item.localFile }

    var body: some View {
        content
            .task { await load() }
            .onDisappear {
                // Released rather than only paused. A paused AVPlayer still holds its item and
                // its decode buffers, and pages are created and destroyed as somebody swipes
                // through an afternoon's photos.
                player?.pause()
                player = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        if kind == .video, let player {
            VideoPlayer(player: player)
                .ignoresSafeArea()
        } else if let image {
            #if canImport(UIKit)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom * pinch)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        // Clamped between actual size and 4×: a photo zoomed to a thousandth
                        // is a lost photo, and there is no way back from it with one finger.
                        .onEnded { value in zoom = min(4, max(1, zoom * value.magnification)) }
                )
                .onTapGesture(count: 2) {
                    withAnimation(Motion.tap) { zoom = zoom > 1 ? 1 : 2 }
                }
            #endif
        } else if failed {
            unavailable
        } else {
            ProgressView().tint(.surface)
        }
    }

    /// Says what happened and what to do. Never an apology, and never a suggestion that the
    /// archive lost something — the bytes are in storage and this is a fetch that did not land.
    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.surface.opacity(0.7))
            Text("Can't load this right now")
                .typeRole(.title)
                .foregroundStyle(Color.surface)
            Text("It's safe in the archive. Try again when you have a connection.")
                .typeRole(.body)
                .foregroundStyle(Color.surface.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(Layout.screenMargin * 2)
    }

    private func load() async {
        if kind == .video {
            guard let url = await MediaAccess.playbackURL(mediaId: mediaId, localFile: localFile, api: api) else {
                failed = true
                return
            }
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
            return
        }

        #if canImport(UIKit)
        guard let data = await MediaAccess.fullImageData(mediaId: mediaId, localFile: localFile, api: api),
              let decoded = UIImage(data: data)
        else {
            failed = true
            return
        }
        image = decoded
        #else
        failed = true
        #endif
    }
}
