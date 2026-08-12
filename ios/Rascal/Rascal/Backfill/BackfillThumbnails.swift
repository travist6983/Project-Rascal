import SwiftUI

/// The contact-sheet grid's geometry, in one place so a tile's rect is arithmetic rather than a
/// consequence of how SwiftUI happened to resolve an aspect ratio.
///
/// The numbers are `docs/design-system.md`'s **Backfill photo grid**: three flexible columns, 3pt
/// gutters both ways, square tiles at radius 2, screen-margin sides. They are deliberately not the
/// mosaic's — "tight gutters and square corners are what make a month scan as a contact sheet;
/// mosaic rounding at this density reads as forty separate cards."
nonisolated enum BackfillGrid {
    static let columns = 3
    static let gutter: CGFloat = 3
    static let cornerRadius: CGFloat = 2

    /// The side of one tile, in points, floored to a whole point.
    ///
    /// Floored rather than rounded: three tiles plus two gutters must not exceed the content width,
    /// and a fractional side that rounds up puts the third column a hair past the margin on every
    /// row. The leftover sub-point lands in the trailing margin, where nobody can see it.
    ///
    /// `margin` is passed rather than defaulted to `Layout.screenMargin`, which is main-actor
    /// isolated where this is not. Naming the token at the call site keeps one definition of the
    /// screen margin and lets this stay a pure function the tests can call from anywhere.
    static func tileSide(forWidth width: CGFloat, margin: CGFloat) -> CGFloat {
        let gutters = gutter * CGFloat(columns - 1)
        let available = width - margin * 2 - gutters
        return max(1, (available / CGFloat(columns)).rounded(.down))
    }

    /// The request size, in **pixels**. `PHImageManager` takes pixels; handing it points asks for a
    /// third of the picture on a 3× phone and gets back something soft.
    static func pixelSize(forTileSide side: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((side * scale).rounded()))
    }
}

/// Thumbnails for the picker grid, fetched once and kept for as long as the flow is open.
///
/// Separate from `ThumbnailStore`, which caches *archive* media fetched from the server. These are
/// camera-roll assets that have not become anything yet: they never touch the network, they are
/// never written to staging, and they go away with the flow. Reusing the archive's cache for them
/// would put photos the parent has not chosen into the store the timeline draws from.
@MainActor
@Observable
final class BackfillThumbnailLoader {
    private let source: any BackfillAssetSource
    private let maxPixel: Int
    private let limit: Int

    private var cache: [String: Data] = [:]
    /// Insertion order, for eviction. A month can hold hundreds of photos and the grid scrolls
    /// through all of them; without a bound this grows for as long as the sheet is open.
    private var order: [String] = []
    /// Assets PhotoKit had nothing local for. Remembered so a tile that came back empty is not
    /// re-requested on every redraw — a cloud-only asset would otherwise retry forever.
    private var unavailable: Set<String> = []

    /// One month's assets, kept for as long as the flow is open.
    ///
    /// The card strip and the picker both want the same month, and a parent moving between them is
    /// the normal path — fetching twice would walk the library twice for the same answer.
    private var monthAssets: [String: [BackfillAsset]] = [:]

    init(source: any BackfillAssetSource, maxPixel: Int = 320, limit: Int = 240) {
        self.source = source
        self.maxPixel = maxPixel
        self.limit = limit
    }

    func assets(in month: BackfillMonth) async throws -> [BackfillAsset] {
        if let hit = monthAssets[month.key] { return hit }
        let fetched = try await source.assets(in: month)
        monthAssets[month.key] = fetched
        return fetched
    }

    func thumbnail(for assetId: String, pixelSize: Int? = nil) async -> Data? {
        let px = pixelSize ?? maxPixel
        // **Keyed on the size as well as the asset.** The suggested-month strip asks for 320 and the
        // picker's grid asks for its own tile side in pixels, and the same photograph appears in
        // both — an asset-only key hands the grid whichever size happened to be fetched first, so a
        // tile renders upscaled and soft for no reason anyone can see.
        let key = "\(assetId)@\(px)"
        if let hit = cache[key] { return hit }
        // Availability is a fact about the asset, not about the size asked for.
        if unavailable.contains(assetId) { return nil }

        guard let data = await source.thumbnail(for: assetId, maxPixel: px) else {
            // A cancelled request also lands here. Recording it as unavailable would blacklist a
            // perfectly good photo because the parent scrolled past it quickly, so a cancellation
            // is left un-remembered and the tile simply asks again next time it appears.
            if !Task.isCancelled { unavailable.insert(assetId) }
            return nil
        }
        store(data, for: key)
        return data
    }

    /// Warm the window the parent is about to reach, and let go of the one behind them.
    ///
    /// Straight through to `PHCachingImageManager`, which decodes ahead on its own queue. The
    /// loader's own dictionary is the second tier — this one keeps the *next* rows ready, that one
    /// keeps the bytes for rows already seen.
    func startCaching(_ assetIds: [String], pixelSize: Int) {
        source.startCachingThumbnails(assetIds, maxPixel: pixelSize)
    }

    func stopCaching(_ assetIds: [String], pixelSize: Int) {
        source.stopCachingThumbnails(assetIds, maxPixel: pixelSize)
    }

    /// Everything, on the way out of the picker. A caching manager left holding a month of photos
    /// keeps them decoded for the life of the process.
    func stopCachingEverything() {
        source.stopCachingAllThumbnails()
    }

    private func store(_ data: Data, for key: String) {
        cache[key] = data
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}

/// One tile in a backfill grid.
///
/// Three states, and the third is the point: a photo that is only in iCloud renders as plainly
/// unavailable rather than as a tile that never finishes loading. The scan counted it, so pretending
/// it is not there would make the count wrong; fetching it would break the promise that nothing
/// downloads.
///
/// **It occupies exactly the space it is given, whatever shape the photograph is.** The previous
/// version put `.scaledToFill()` under a `.clipShape` with no frame between them, and a clip shape
/// is sized to the *view's own bounds* rather than to the space proposed — so a portrait asset in a
/// square cell grew its own bounds, clipped itself to that larger square, and drew over its
/// neighbours. In a `LazyVGrid` a row is as tall as its tallest child, so one overflowing tile also
/// pushed its row into the next one and painted across the pinned day header above it. Three
/// symptoms, one defect. `Color.clear` takes the proposed size, the picture rides in an overlay
/// that cannot influence layout, and the clip lands on the proposal.
struct BackfillThumbnail: View {
    let asset: BackfillAsset
    var cornerRadius: CGFloat = Layout.mediaInsetRadius
    /// Pixels, not points — see `BackfillThumbnailLoader`. The grid asks for its own tile side
    /// times the screen scale; the strip keeps the loader's default.
    var pixelSize: Int?

    @Environment(BackfillThumbnailLoader.self) private var loader
    #if canImport(UIKit)
    /// Decoded **once**, when the tile appears — not in `body`.
    ///
    /// Holding the JPEG and calling `UIImage(data:)` inside `body` re-decoded the picture on every
    /// redraw: once per scroll frame, per tile, for as long as the grid moved. The bytes are what
    /// the loader caches, because they are a twentieth the size of the decoded image; the decode
    /// belongs here, where it dies with the tile.
    @State private var image: UIImage?
    #endif

    var body: some View {
        shape
            // `.task(id:)` **is** the cancellation. SwiftUI cancels it when the tile leaves the
            // grid or the identity changes, and `PhotoLibraryBackfillSource.thumbnail` turns that
            // cancellation into `PHImageManager.cancelImageRequest`. A fast flick therefore leaves
            // no requests resolving into tiles that no longer exist.
            //
            // **The size is part of the identity.** The grid seeds its width and corrects it in the
            // same layout pass, so the pixel size can change once on the first frame; keyed on the
            // asset alone the tile would keep whatever it asked for against the seeded width and
            // render soft on any phone that is not 393 wide.
            .task(id: "\(asset.id)@\(pixelSize ?? 0)") {
                guard asset.isOnDevice else { return }
                let data = await loader.thumbnail(for: asset.id, pixelSize: pixelSize)
                #if canImport(UIKit)
                guard !Task.isCancelled, let data else { return }
                image = UIImage(data: data)
                #endif
            }
    }

    private var shape: some View {
        // `Color.clear` accepts whatever size the cell proposes and the overlay cannot change it,
        // which is what makes the tile's rect independent of the asset's aspect ratio.
        Color.clear
            .overlay {
                #if canImport(UIKit)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
                #else
                placeholder
                #endif
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var placeholder: some View {
        if asset.isOnDevice {
            // Loading. A neutral fill rather than a spinner: a grid of forty spinners reads as
            // forty things going wrong.
            Color.chipPlain
        } else {
            ZStack {
                Color.chipPlain
                Image(systemName: "icloud")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Color.inkFaint)
            }
        }
    }
}
