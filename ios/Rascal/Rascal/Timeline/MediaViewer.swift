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
    let onOpen: () -> Void

    @Environment(\.thumbnails) private var thumbnails
    @State private var poster: PlatformImage?

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Color.terracottaSoft
                #if canImport(UIKit)
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                }
                #endif
                if kind == .video { playGlyph }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .task(id: mediaId) {
            #if canImport(UIKit)
            poster = await thumbnails?.image(for: mediaId, kind: kind)
            #endif
        }
        .accessibilityLabel(kind == .video ? "Video, tap to play" : "Photo, tap to open")
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
    let mediaId: UUID
    let kind: PromptKind
    /// The staged original where this phone still has it. Free, and identical to what storage
    /// holds — the sweep only removes an original the server has acknowledged.
    let localFile: URL?
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack {
            // Not pure black even here. The palette has no #000, and a dark warm ground reads
            // better against cream photos than a void does.
            Color.ink.ignoresSafeArea()

            content

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
        .task { await load() }
        .onDisappear { player?.pause() }
        .statusBarHidden()
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
