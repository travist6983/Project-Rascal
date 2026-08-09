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
    /// A fixed square, or the whole cell it is handed. `fill` is what the timeline's mosaic
    /// uses: the grid decides each tile's shape, and the tile fills it.
    var sizing: Sizing = .square(56)
    var cornerRadius: CGFloat = 12
    /// Off inside the mosaic, where the 4pt gutters already separate the tiles and the card
    /// showing through them is the only line the grid needs.
    var bordered: Bool = true
    /// The kind glyph on a tile with no picture yet. Off on the tile carrying the `+5` count,
    /// where a camera icon behind the number is two marks fighting over one square — the design
    /// puts that scrim over a photograph, and a placeholder is not one.
    var showsGlyph: Bool = true
    /// Overlaid bottom-trailing on a video tile.
    var durationSeconds: Int?

    enum Sizing: Equatable {
        case square(CGFloat)
        case fill

        var side: CGFloat? {
            if case .square(let side) = self { return side }
            return nil
        }
    }

    @Environment(\.thumbnails) private var thumbnails
    @State private var image: PlatformImage?

    var body: some View {
        content
            .frame(width: sizing.side, height: sizing.side)
            // A filled tile is sized by its cell and clipped to it. Without this the
            // `scaledToFill` above would let a landscape photo push its whole grid wider.
            .frame(maxWidth: sizing.side == nil ? .infinity : nil,
                   maxHeight: sizing.side == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                }
            }
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
            if showsGlyph {
                Image(systemName: kind == .video ? "video.fill" : kind.symbol)
                    // A filled tile has no side to scale against; 22pt reads correctly across
                    // the whole mosaic, from a 108pt quarter up to a 242pt single.
                    .font(.system(size: (sizing.side.map { $0 * 0.3 }) ?? 22, weight: .regular))
                    .foregroundStyle(tint.ink)
            }
        }
    }

    private var tint: (soft: Color, ink: Color) {
        switch kind {
        case .audio: (.periwinkleSoft, .periwinkle)
        case .photo, .video: (.terracottaSoft, .terracotta)
        default: (.border, .inkMuted)
        }
    }

    /// A tile too small to hold the badge legibly goes without it. A filled tile is never that
    /// small — the smallest cell in the mosaic is a 108pt quarter.
    @ViewBuilder
    private var durationBadge: some View {
        if let durationSeconds, kind == .video, sizing.side.map({ $0 >= 48 }) ?? true {
            Text(DurationText.clock(durationSeconds))
                .font(.system(size: sizing.side == nil ? 11.5 : 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.canvas)
                .padding(.horizontal, sizing.side == nil ? 10 : 5)
                .padding(.vertical, sizing.side == nil ? 4 : 2)
                .background(Color.ink.opacity(0.62), in: Capsule())
                .padding(sizing.side == nil ? 9 : 4)
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
