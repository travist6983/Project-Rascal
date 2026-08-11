import SwiftUI

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

    func thumbnail(for assetId: String) async -> Data? {
        if let hit = cache[assetId] { return hit }
        if unavailable.contains(assetId) { return nil }

        guard let data = await source.thumbnail(for: assetId, maxPixel: maxPixel) else {
            unavailable.insert(assetId)
            return nil
        }
        store(data, for: assetId)
        return data
    }

    private func store(_ data: Data, for assetId: String) {
        cache[assetId] = data
        order.append(assetId)
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
struct BackfillThumbnail: View {
    let asset: BackfillAsset
    var cornerRadius: CGFloat = Layout.mediaInsetRadius

    @Environment(BackfillThumbnailLoader.self) private var loader
    @State private var data: Data?

    var body: some View {
        shape
            .task(id: asset.id) {
                guard asset.isOnDevice else { return }
                data = await loader.thumbnail(for: asset.id)
            }
    }

    @ViewBuilder
    private var shape: some View {
        Group {
            #if canImport(UIKit)
            if let data, let image = UIImage(data: data) {
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
