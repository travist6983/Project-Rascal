import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// One square of picture, or an honest stand-in for one.
///
/// The stand-in matters as much as the picture. `thumb_key` is null on every media row, video is
/// never downloaded for a poster frame, and a photo whose bytes are still on the way has nothing
/// to draw — so a tile with no image is the ordinary case, not the error case. It renders as a
/// tinted square in the colour that kind of media owns, which reads as "a video" rather than as
/// "something failed".
struct MediaThumbnail: View {
    let mediaId: UUID
    let kind: PromptKind
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 12
    /// Overlaid bottom-trailing on a video tile.
    var durationSeconds: Int?

    @Environment(\.thumbnails) private var thumbnails
    @State private var image: PlatformImage?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            .overlay(alignment: .bottomTrailing) { durationBadge }
            .task(id: mediaId) { await load() }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(UIKit)
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    /// Colour carries meaning here too: terracotta is photo and video, periwinkle is voice.
    private var placeholder: some View {
        ZStack {
            tint.soft
            Image(systemName: kind == .video ? "video.fill" : kind.symbol)
                .font(.system(size: size * 0.3, weight: .regular))
                .foregroundStyle(tint.ink)
        }
    }

    private var tint: (soft: Color, ink: Color) {
        switch kind {
        case .audio: (.periwinkleSoft, .periwinkle)
        case .photo, .video: (.terracottaSoft, .terracotta)
        default: (.border, .inkMuted)
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let durationSeconds, kind == .video, size >= 48 {
            Text(DurationText.clock(durationSeconds))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.surface)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.ink.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }

    private func load() async {
        #if canImport(UIKit)
        // The synchronous hit first, so a card scrolling back into view does not flash a
        // placeholder it already has the picture for.
        if let cached = thumbnails?.cached(mediaId) {
            image = cached
            return
        }
        image = await thumbnails?.image(for: mediaId, kind: kind)
        #endif
    }
}

/// `UIImage` where there is UIKit. The alias keeps the `#if` out of every view that holds one.
#if canImport(UIKit)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = Never
#endif

/// The `+8` at the end of a thumbnail row. Neutral on purpose — it is a count, not a picture,
/// and tinting it terracotta would make it read as the most important tile in the row.
struct OverflowTile: View {
    let count: Int
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 12

    var body: some View {
        Text("+\(count)")
            .typeRole(.metadata)
            .foregroundStyle(Color.inkMuted)
            .frame(width: size, height: size)
            .background(Color.border, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}
