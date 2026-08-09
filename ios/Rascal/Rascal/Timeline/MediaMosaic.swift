import SwiftUI

/// The pictures on an entry card, laid out as one block rather than a row of squares.
///
/// Four shapes, chosen by how many tiles there are to draw: a single, a pair, a big-plus-two
/// trio, and a 2×2. Past four the count is **printed on the fourth tile** instead of taking a
/// tile of its own — which is what keeps a card holding nine photos exactly as tall as one
/// holding four, so a long scroll has one rhythm rather than a stair.
///
/// The block clips to a single rounded rectangle and the tiles inside it are square-cornered.
/// The 4pt gutters are the card showing through, not a border on each tile: a hairline around
/// every cell turns a mosaic into a contact sheet.
///
/// **Nothing here is reachable unless the entry has media.** A written or did-it entry never
/// renders this view at all — not at zero height, not as an empty frame. See `EntryCard`.
struct MediaMosaic: View {
    let tiles: [EntryCardModel.Thumbnail]
    /// Pictures beyond the four drawn. Rendered as `+5` over the last tile.
    var overflow: Int = 0

    /// The four shapes, to the pixel values in the v3 design.
    private enum Metric {
        static let gap: CGFloat = 4
        /// A lone photo is given real height — it is the entry, not an illustration of it.
        static let single: CGFloat = 242
        /// Video sits shorter than a photo: it reads as a frame from something, not a print.
        static let singleVideo: CGFloat = 196
        static let pair: CGFloat = 164
        static let trio: CGFloat = 216
        /// Each row of the 2×2. The block is `108 * 2 + gap`.
        static let quadRow: CGFloat = 108
        /// The wide tile's share of the trio, leaving the stacked pair the rest.
        static let trioLeadingShare: CGFloat = 0.62
    }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch tiles.count {
        case 0: EmptyView()
        case 1: single
        case 2: pair
        case 3: trio
        default: quad
        }
    }

    // MARK: Shapes

    @ViewBuilder
    private var single: some View {
        if let only = tiles.first {
            tile(only, isLast: true)
                .frame(height: only.kind == .video ? Metric.singleVideo : Metric.single)
        }
    }

    private var pair: some View {
        HStack(spacing: Metric.gap) {
            tile(tiles[0], isLast: false)
            tile(tiles[1], isLast: true)
        }
        .frame(height: Metric.pair)
    }

    /// One wide tile carrying the entry, and two stacked beside it.
    ///
    /// `GeometryReader` because the split is 62/38 rather than even, and the height it sits in
    /// is fixed — so this reads the width and nothing feeds back into it.
    private var trio: some View {
        GeometryReader { geometry in
            let leading = (geometry.size.width - Metric.gap) * Metric.trioLeadingShare
            HStack(spacing: Metric.gap) {
                tile(tiles[0], isLast: false)
                    .frame(width: leading)
                VStack(spacing: Metric.gap) {
                    tile(tiles[1], isLast: false)
                    tile(tiles[2], isLast: true)
                }
            }
        }
        .frame(height: Metric.trio)
    }

    private var quad: some View {
        VStack(spacing: Metric.gap) {
            HStack(spacing: Metric.gap) {
                tile(tiles[0], isLast: false)
                tile(tiles[1], isLast: false)
            }
            .frame(height: Metric.quadRow)
            HStack(spacing: Metric.gap) {
                tile(tiles[2], isLast: false)
                tile(tiles[3], isLast: true)
            }
            .frame(height: Metric.quadRow)
        }
    }

    // MARK: Tiles

    private func tile(_ thumbnail: EntryCardModel.Thumbnail, isLast: Bool) -> some View {
        let carriesCount = isLast && overflow > 0
        return MediaThumbnail(
            mediaId: thumbnail.id,
            kind: thumbnail.kind,
            sizing: .fill,
            cornerRadius: 0,
            bordered: false,
            showsGlyph: !carriesCount,
            durationSeconds: thumbnail.durationSeconds
        )
        .overlay { if carriesCount { overflowScrim } }
    }

    /// `+5`, over a terracotta wash. It is a count of pictures, so it wears the colour pictures
    /// wear — and it sits *on* the last tile rather than replacing it, because a tile spent on a
    /// number is a picture the parent does not get to see.
    private var overflowScrim: some View {
        ZStack {
            Color.terracotta.opacity(0.30)
            Text("+\(overflow)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.canvas)
        }
    }
}
