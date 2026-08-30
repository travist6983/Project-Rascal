import SwiftUI

/// The contact-sheet grid's geometry, in one place so a tile's rect is arithmetic rather than a
/// consequence of how SwiftUI happened to resolve an aspect ratio.
///
/// The numbers are `docs/design-system.md`'s **Backfill photo grid**: three columns, 3pt gutters
/// both ways, square tiles at radius 2, screen-margin sides. They are deliberately not the
/// mosaic's — "tight gutters and square corners are what make a month scan as a contact sheet;
/// mosaic rounding at this density reads as forty separate cards."
///
/// The columns are `.fixed(tileSide)` rather than `.flexible()`: one number then decides the tile's
/// frame, its clip and the pixel size asked of PhotoKit, instead of the view having to guess at a
/// width the grid resolved for itself.
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
    /// Keyed by `BackfillMonth.key`, and the month itself is kept beside the assets so
    /// `revalidate()` can ask the library about it again without reconstructing one from a string.
    private var monthAssets: [String: (month: BackfillMonth, assets: [BackfillAsset])] = [:]

    /// Bumped whenever what the library will show us changes. **Screens key their `.task(id:)` on
    /// it**, because a month's key is invariant and a task keyed on that alone cannot re-run.
    ///
    /// This is the observable half of `forgetAssets()`: clearing the dictionary is necessary and
    /// on its own achieves nothing visible, since every reader is already sitting on a task that
    /// will not fire again for the month it is showing.
    private(set) var generation = 0

    init(source: any BackfillAssetSource, maxPixel: Int = 320, limit: Int = 240) {
        self.source = source
        self.maxPixel = maxPixel
        self.limit = limit
    }

    func assets(in month: BackfillMonth) async throws -> [BackfillAsset] {
        if let hit = monthAssets[month.key] { return hit.assets }
        // **Stamped before the await and checked after it.** A fetch already in flight when the
        // grant changes — or when "Share more photos" lands — resolves with the pre-change list,
        // and writing that back would repopulate the memo `forgetAssets()` just emptied, under the
        // new generation, where nothing would ever clear it again. The caller still gets what it
        // asked for; it is only the memo that refuses the stale answer, and the re-keyed `.task`
        // is already on its way with a fresh one.
        let asked = generation
        let fetched = try await source.assets(in: month)
        if generation == asked { monthAssets[month.key] = (month, fetched) }
        return fetched
    }

    /// Ask the library whether the months already on screen still hold the same photographs, and
    /// drop everything if they do not.
    ///
    /// **This replaced a comparison of `scanner.months`, which could not answer the question.** A
    /// `BackfillMonthSummary` is `(month, assetCount, entryCount)` and nothing else, so a parent
    /// who edits a Selected Photos grant to swap one October picture for another produces an
    /// identical index — the invalidation never fired, the grid kept drawing a photo the app can
    /// no longer read, and the one just shared never appeared. It was also wrong in the other
    /// direction: `entryCount` moves when the *archive* gains an entry, which has nothing to do
    /// with the camera roll, and tore the grid down for it.
    ///
    /// Only months already in the memo are asked about. That is the set whose staleness anybody
    /// can see, it is a handful under `.limited`, and it is empty on the common path — a parent
    /// who has not opened a month pays nothing.
    ///
    /// Returns whether anything moved, so a caller can tell a foreground that changed something
    /// from one that did not.
    @discardableResult
    func revalidate() async -> Bool {
        guard !monthAssets.isEmpty else { return false }
        for (_, known) in monthAssets {
            guard let fresh = try? await source.assets(in: known.month) else { continue }
            // **The whole asset, not just its id.** `BackfillAsset` is `Equatable` over all three
            // of its fields and the fetch is already paid for, so comparing ids alone threw away
            // the two that every screen actually decides from. `isOnDevice` flips when a parent
            // downloads an Optimize-Storage original — the exact remedy the iCloud badge invites —
            // and an id-only check called that no change, leaving the tile badged and unselectable
            // for a photograph now sitting on the phone; offloading flips it the other way, into a
            // blank tile that is still selectable. And `creationDate` moves when somebody uses
            // Photos' *Adjust Date & Time*, which would leave the picker grouping the photo under
            // a stale day and handing that stale day to `BackfillEntryPlan` as the entry's
            // `occurred_at` — the one error this whole feature exists to prevent.
            if fresh != known.assets {
                forgetAssets()
                return true
            }
        }
        return false
    }

    /// Drop everything read out of the library, because what the library will show us has changed.
    ///
    /// **The memo above had no invalidation path at all, and that made the one affordance a
    /// `.limited` parent is offered unable to change what is on screen.** "Share more photos"
    /// widened the selection and forced a rescan, so a month card's *total* updated — while its
    /// thumbnails, and the grid behind it, were the pre-widen fetch. The card then printed a new
    /// number over old pictures, and opening that month showed a smaller count directly under the
    /// larger one it was tapped from. Only dismissing the whole flow could clear it.
    ///
    /// The thumbnail bytes and the unavailable set go too. A narrowed grant can make a photo that
    /// was readable a moment ago unreadable, and a cached tile would keep drawing it.
    func forgetAssets() {
        monthAssets.removeAll()
        cache.removeAll()
        order.removeAll()
        unavailable.removeAll()
        generation &+= 1
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
    /// **The loader remembers what each window was started with, and stops it with exactly that.**
    /// `PHCachingImageManager` releases a window only when `stop` is given the same assets at the
    /// same target size, and the caller cannot be trusted to hand back the same size it handed in:
    /// the picker seeds its width and corrects it in the same layout pass, so a day whose `onAppear`
    /// fired against the seed and whose `onDisappear` fires against the real width would stop a
    /// window that was never started — leaving the started one decoded for the life of the screen,
    /// which is the exact memory this caching is here to bound.
    ///
    /// The loader's own dictionary is the second tier: this one keeps the *next* rows ready, that
    /// one keeps the bytes for rows already seen.
    private var cachingWindows: [String: (ids: [String], pixelSize: Int)] = [:]

    func startCaching(_ assetIds: [String], pixelSize: Int, forWindow key: String) {
        if let existing = cachingWindows[key] {
            // Already warm at this size. Re-warming would double the manager's book-keeping for
            // one window, and only one `stop` is ever going to arrive.
            guard existing.pixelSize != pixelSize else { return }
            source.stopCachingThumbnails(existing.ids, maxPixel: existing.pixelSize)
        }
        cachingWindows[key] = (assetIds, pixelSize)
        source.startCachingThumbnails(assetIds, maxPixel: pixelSize)
    }

    func stopCaching(forWindow key: String) {
        guard let window = cachingWindows.removeValue(forKey: key) else { return }
        source.stopCachingThumbnails(window.ids, maxPixel: window.pixelSize)
    }

    /// Everything, on the way out of the picker. A caching manager left holding a month of photos
    /// keeps them decoded for the life of the process. This is also the backstop for a window whose
    /// `onDisappear` never arrived, which is what a dismissed screen does to its children.
    func stopCachingEverything() {
        cachingWindows.removeAll()
        source.stopCachingAllThumbnails()
    }

    /// How many windows are warm. Test-facing: the pairing is invisible from the outside otherwise,
    /// and an unpaired `start` is a leak that nothing on screen reveals.
    var warmWindowCount: Int { cachingWindows.count }

    private func store(_ data: Data, for key: String) {
        // **Appended only when the key is new.** There is an `await` between the cache check and
        // this call, so two tiles asking for the same photograph at the same size both miss and
        // both land here — and a key recorded twice in `order` evicts its `cache` entry on the
        // first pass and then removes nothing on the second. The cache would quietly hold fewer
        // than `limit` thumbnails, refetching pictures it had already paid for.
        if cache[key] == nil { order.append(key) }
        cache[key] = data
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
            // **The generation is in the key, like every other reload in this feature.** An
            // asset's id does not move when its availability does, so a tile keyed on the id alone
            // survived the very invalidation `revalidate()` exists to trigger: the parent
            // downloads an offloaded original — the remedy the iCloud badge invites — the loader
            // correctly tears the memo down and rebuilds the day groups, and this task never
            // re-runs. The tile then draws neither the photograph nor the badge, and is selectable.
            .task(id: "\(asset.id)@\(pixelSize ?? 0)#\(loader.generation)") {
                // Cleared rather than left standing: this tile is reused for the same asset in a
                // new generation, and a picture fetched under the old one may no longer be readable.
                guard asset.isOnDevice else {
                    #if canImport(UIKit)
                    image = nil
                    #endif
                    return
                }
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
