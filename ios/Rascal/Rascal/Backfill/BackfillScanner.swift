import CoreGraphics
import Foundation

#if canImport(Photos)
import Photos
#endif

// `presentLimitedLibraryPicker(from:)` is declared in PhotosUI, not Photos — see
// `LimitedLibraryPicker`. Importing Photos alone compiles everything else here and fails only on
// that one call, with an error that reads as an availability problem rather than a missing import.
#if canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Where the asset dates come from. The seam that keeps PhotoKit out of every assertion.
nonisolated protocol BackfillAssetSource: Sendable {
    func authorization() async -> BackfillAuthorization
    /// Ask the system, once.
    ///
    /// **Only ever called from behind the explainer.** iOS shows its prompt a single time and a
    /// denial is close to permanent — there is no second ask, and this app does not build one. So
    /// the explainer earns the prompt first, and this is what it calls when the parent agrees.
    /// Already-decided states return what was already decided without showing anything.
    func requestAuthorization() async -> BackfillAuthorization
    /// Every asset's creation date, and which of them are not on the device.
    ///
    /// **Incremental and cancellable.** Implementations must check `Task.isCancelled` as they go
    /// and must never run on the main thread — a library with 40,000 assets in it would otherwise
    /// block the app for seconds.
    func creationDates() async throws -> (onDevice: [Date], cloudOnly: [Date])
    /// Opaque token that changes when the library does, for cache invalidation. `nil` when the
    /// platform offers none.
    func libraryToken() async -> String?

    /// Every asset in one month, oldest first.
    ///
    /// **Called only once the parent has opened a month.** The scan deliberately never asks for
    /// this: identifying individual photos is a different act from counting them, and it does not
    /// happen until someone has chosen to look.
    func assets(in month: BackfillMonth) async throws -> [BackfillAsset]

    /// Thumbnail bytes for one asset, or `nil` when none can be produced without going to the
    /// network. A cloud-only asset lands here as `nil` and renders as unavailable.
    func thumbnail(for assetId: String, maxPixel: Int) async -> Data?

    /// Full-resolution bytes for one asset, on their way to `ImagePipeline`.
    ///
    /// **Never downloads.** Throws for an asset that is not on the device, which is why the picker
    /// refuses to select one in the first place.
    func imageData(for assetId: String) async throws -> Data

    /// Decode ahead of the scroll, and let go behind it.
    ///
    /// Optional, with no-op defaults: these exist for `PHCachingImageManager` and there is nothing
    /// for a stub of `Date` values to do with them. A source that does not implement them is not
    /// broken, only uncached — which is exactly what every test fake wants to be.
    func startCachingThumbnails(_ assetIds: [String], maxPixel: Int)
    func stopCachingThumbnails(_ assetIds: [String], maxPixel: Int)
    /// On the way out of the picker. A caching manager still holding a month keeps it decoded for
    /// the life of the process.
    func stopCachingAllThumbnails()
}

extension BackfillAssetSource {
    func startCachingThumbnails(_ assetIds: [String], maxPixel: Int) {}
    func stopCachingThumbnails(_ assetIds: [String], maxPixel: Int) {}
    func stopCachingAllThumbnails() {}
}

/// What went wrong reaching for a photo's bytes.
nonisolated enum BackfillAssetError: Error, Equatable {
    /// The asset lives only in iCloud, and this feature does not download.
    case notOnDevice
    /// The asset is gone, or the identifier belongs to another library.
    case missing
    case unreadable
}

/// The scan, as the app runs it.
///
/// Nothing here creates an assignment. Nothing here uploads, transmits, or logs asset content —
/// **nothing leaves the device until the parent picks something.** The scan reads dates and
/// counts and produces months; it never touches pixels.
@MainActor
@Observable
final class BackfillScanner {

    enum State: Equatable {
        case idle
        case scanning
        /// Finished. `clusters` may legitimately be empty — a parent who logs every month has
        /// nothing to backfill, and that is a success.
        case ready([BackfillCluster])
        /// Access was refused. Reported without a retry funnel; the app behaves identically.
        case unavailable
    }

    private(set) var state: State = .idle
    /// What the system last said, verbatim.
    ///
    /// **Published because the `+` sheet needs it before any backfill screen exists.** That row
    /// is present in every state — it is the door to the explainer — but what it *says* differs,
    /// and under `.limited` it must not state a month count as though it were complete. `state`
    /// alone cannot carry that: `.unavailable` is both "never asked" and "refused", and those two
    /// get different sentences.
    ///
    /// `.notDetermined` until a scan has read one, which is the honest default — nothing has been
    /// counted yet, so nothing is claimed.
    private(set) var authorization: BackfillAuthorization = .notDetermined
    /// True when the parent granted access to selected photos only. **Not an error** — the UI
    /// says what it can see rather than pretending it saw everything.
    private(set) var isLimitedLibrary = false
    /// Every month holding a photo, for the "Every month" browse list. Unfiltered — see
    /// `BackfillPlan.monthIndex`. Empty until a scan has run.
    private(set) var months: [BackfillMonthSummary] = []
    /// Months the parent has waved away, as `BackfillMonth.key`.
    ///
    /// **Published because `SUGGESTED` is no longer the cluster list.** The browse screen builds its
    /// own five candidates from `months` and has to apply the same dismissals the clusters do —
    /// reading the store from the view would be a second source for one answer, and one of the two
    /// would eventually stop being refreshed.
    private(set) var dismissedMonths: Set<String> = []

    private let source: any BackfillAssetSource
    private let dismissals: any BackfillDismissalStoring
    private let cache: BackfillScanCaching
    private var task: Task<Void, Never>?

    init(
        source: any BackfillAssetSource,
        dismissals: any BackfillDismissalStoring = UserDefaultsBackfillDismissalStore(),
        cache: BackfillScanCaching = UserDefaultsBackfillScanCache()
    ) {
        self.source = source
        self.dismissals = dismissals
        self.cache = cache
        // Read at init rather than at the first scan. The browse screen can be reached before a
        // scan has completed — a cached result renders immediately — and a dismissal recorded last
        // week must not reappear for the length of that first render.
        self.dismissedMonths = dismissals.dismissed()
    }

    /// `entryDates` is every `occurred_at` this device holds, read from the local store by the
    /// caller. Compared locally and never by asking the server.
    func scan(entryDates: [Date], now: Date = Date(), force: Bool = false) {
        task?.cancel()
        task = Task { await run(entryDates: entryDates, now: now, force: force) }
    }

    /// The same scan, awaited.
    ///
    /// For a screen that has to show a result rather than react to one. Awaiting the task is the
    /// point: polling `state` in a loop would spin the main actor for the length of a scan, which
    /// on a large library is exactly the case this feature has to stay cheap for.
    func scanAndWait(entryDates: [Date], now: Date = Date(), force: Bool = false) async {
        scan(entryDates: entryDates, now: now, force: force)
        await task?.value
    }

    /// **Cancellable mid-run, leaving no partial state.** The published `state` is only ever
    /// written with a complete result, so a cancelled scan leaves whatever was there before
    /// rather than a half-built list.
    func cancel() {
        task?.cancel()
        task = nil
        if state == .scanning { state = .idle }
    }

    private func run(entryDates: [Date], now: Date, force: Bool) async {
        let granted = await source.authorization()
        // Recorded before the guard, so a refusal is still a *known* refusal rather than an
        // absence. The `+` sheet says something different for "never asked" than for "said no".
        authorization = granted
        guard granted.canScan else {
            state = .unavailable
            return
        }
        isLimitedLibrary = granted == .limited

        let token = await source.libraryToken()
        if !force, let cached = cache.load(), cached.isFresh(now: now, token: token) {
            months = cached.asMonths
            state = .ready(filtered(cached.asClusters))
            return
        }

        state = .scanning
        guard let dates = try? await source.creationDates() else {
            // Silent and non-fatal. A scan that could not run is not something a parent can act
            // on, and this feature is an offer rather than a promise.
            state = .idle
            return
        }
        guard !Task.isCancelled else {
            state = .idle
            return
        }

        let dismissed = dismissals.dismissed()
        dismissedMonths = dismissed
        let clusters = BackfillPlan.clusters(
            assetDates: dates.onDevice,
            cloudOnlyDates: dates.cloudOnly,
            entryDates: entryDates,
            dismissed: dismissed
        )
        let index = BackfillPlan.monthIndex(
            assetDates: dates.onDevice,
            cloudOnlyDates: dates.cloudOnly,
            entryDates: entryDates
        )
        guard !Task.isCancelled else {
            state = .idle
            return
        }
        cache.save(BackfillScanResult.from(clusters, months: index, at: now, token: token))
        months = index
        state = .ready(clusters)
    }

    /// A dismissed month stays dismissed, including against a cached result written before it
    /// was dismissed.
    private func filtered(_ clusters: [BackfillCluster]) -> [BackfillCluster] {
        let dismissed = dismissals.dismissed()
        dismissedMonths = dismissed
        return clusters.filter { !dismissed.contains($0.month.key) }
    }

    func dismiss(_ month: BackfillMonth) {
        dismissals.dismiss(month)
        dismissedMonths = dismissals.dismissed()
        if case .ready(let clusters) = state {
            state = .ready(clusters.filter { $0.month != month })
        }
    }

    /// Undo a dismissal the parent has just made.
    ///
    /// The toast offers this for a few seconds, so the mistake is recoverable at the moment it is
    /// noticed. Deliberately not a general "restore months" facility: a dismissal that has
    /// survived the toast is a decision, and `dismissed()` is where it lives.
    func restore(_ month: BackfillMonth, entryDates: [Date]) {
        dismissals.restore(month)
        // Published before the rescan rather than after it. The rescan is a task, and Undo has to
        // put the month back under the parent's thumb now — not once a library walk has finished.
        dismissedMonths = dismissals.dismissed()
        scan(entryDates: entryDates, force: true)
    }

    /// Ask the system for access, from behind the explainer.
    func requestAccess() async -> BackfillAuthorization {
        let granted = await source.requestAuthorization()
        authorization = granted
        isLimitedLibrary = granted == .limited
        if !granted.canScan { state = .unavailable }
        return granted
    }
}

// MARK: - Caching

nonisolated protocol BackfillScanCaching: Sendable {
    func load() -> BackfillScanResult?
    func save(_ result: BackfillScanResult)
}

nonisolated struct UserDefaultsBackfillScanCache: BackfillScanCaching {
    /// `UserDefaults` is documented thread-safe but carries no `Sendable` conformance, so holding
    /// one in a `Sendable` type needs this said out loud rather than inferred.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "backfill.scan") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> BackfillScanResult? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BackfillScanResult.self, from: data)
    }

    func save(_ result: BackfillScanResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        defaults.set(data, forKey: key)
    }
}

nonisolated final class InMemoryBackfillScanCache: BackfillScanCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BackfillScanResult?

    init(_ stored: BackfillScanResult? = nil) { self.stored = stored }

    func load() -> BackfillScanResult? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ result: BackfillScanResult) {
        lock.lock(); defer { lock.unlock() }
        stored = result
    }
}

// MARK: - PhotoKit

#if canImport(Photos)
/// The thin part. Reads dates and nothing else — no pixels, no identifiers leaving this type.
nonisolated struct PhotoLibraryBackfillSource: BackfillAssetSource {

    func authorization() async -> BackfillAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> BackfillAuthorization {
        // `.readWrite` rather than `.addOnly`: the scan reads dates, and asking for less than the
        // feature needs produces a prompt that grants nothing and cannot be shown again.
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> BackfillAuthorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func libraryToken() async -> String? {
        // No stable public change token without registering an observer, which is more machinery
        // than this needs. Falling back to the cache's age is the honest answer.
        nil
    }

    func creationDates() async throws -> (onDevice: [Date], cloudOnly: [Date]) {
        try await Task.detached(priority: .utility) {
            let options = PHFetchOptions()
            // Dates only. Nothing here requests an image, so nothing triggers an iCloud
            // download — **assets not on the device are counted, never fetched.**
            options.includeHiddenAssets = false
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .image, options: options)

            var onDevice: [Date] = []
            var cloudOnly: [Date] = []
            var cancelled = false

            assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                    return
                }
                guard let created = asset.creationDate else { return }
                // `.isLocallyAvailable` is not public. `PHAsset` exposes no synchronous
                // "downloaded" flag either, so this uses the resource list — which is metadata
                // and does not pull bytes.
                if Self.isOnDevice(asset) {
                    onDevice.append(created)
                } else {
                    cloudOnly.append(created)
                }
            }
            if cancelled { throw CancellationError() }
            return (onDevice, cloudOnly)
        }.value
    }

    /// Metadata only. `PHAssetResource` describes what exists without asking for the bytes, so
    /// this never stalls on and never triggers an iCloud download.
    private static func isOnDevice(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return false }
        return resources.contains { resource in
            (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
        }
    }

    // MARK: One month's assets

    func assets(in month: BackfillMonth) async throws -> [BackfillAsset] {
        try await Task.detached(priority: .userInitiated) {
            let calendar = Calendar.current
            var start = DateComponents()
            start.year = month.year
            start.month = month.month
            start.day = 1
            guard let from = calendar.date(from: start),
                  let to = calendar.date(byAdding: .month, value: 1, to: from)
            else { return [] }

            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            // Bounded by the fetch rather than by filtering afterwards, so a 40,000-asset library
            // does not have to be walked to show one October.
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@", from as NSDate, to as NSDate
            )
            // Oldest first: the picker reads down the month the way the month happened.
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let fetched = PHAsset.fetchAssets(with: .image, options: options)

            var assets: [BackfillAsset] = []
            var cancelled = false
            fetched.enumerateObjects { asset, _, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                    return
                }
                assets.append(
                    BackfillAsset(
                        id: asset.localIdentifier,
                        creationDate: asset.creationDate,
                        isOnDevice: Self.isOnDevice(asset)
                    )
                )
            }
            if cancelled { throw CancellationError() }
            return assets
        }.value
    }

    /// The one caching manager the picker warms.
    ///
    /// **Static because `start` and `stop` have to pair on the same object.** This type is a
    /// struct built fresh wherever it is needed, and a per-instance manager would mean starting a
    /// cache on one and stopping it on another — which leaks the whole month.
    private static let caching = PHCachingImageManager()

    /// Grid thumbnails, and the options are load bearing.
    ///
    /// `.fastFormat` with `.exact` resizing: one callback at exactly the size asked for, rather
    /// than `.fast`'s "some efficient size near it" followed by a second, better decode. With a
    /// fixed tile frame neither can move the layout any more, but a second decode per tile is
    /// still a second decode per tile, and the degraded frame is the one that used to arrive at a
    /// different size and land mid-scroll.
    static func thumbnailOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        // **The whole promise of the scan, kept here too.** A grid of forty tiles that each
        // quietly pull from iCloud is a large download nobody asked for, on a screen someone
        // opened to browse. A cloud-only asset returns nil and renders as unavailable.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .exact
        options.isSynchronous = false
        return options
    }

    func thumbnail(for assetId: String, maxPixel: Int) async -> Data? {
        guard let asset = Self.asset(for: assetId) else { return nil }
        let side = CGFloat(maxPixel)

        // **`withTaskCancellationHandler` is the tile's `cancelImageRequest`.** SwiftUI cancels a
        // `.task(id:)` when its view leaves the grid, and without this that cancellation stopped at
        // the `await` — the request went on resolving, decoding a picture for a tile that no longer
        // existed. A fast flick through a month left hundreds of those in flight at once, which is
        // the memory the grid could not afford.
        let request = ThumbnailRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.attach(continuation)
                let id = Self.caching.requestImage(
                    for: asset,
                    targetSize: CGSize(width: side, height: side),
                    contentMode: .aspectFill,
                    options: Self.thumbnailOptions()
                ) { image, _ in
                    #if canImport(UIKit)
                    request.finish(image?.jpegData(compressionQuality: 0.8))
                    #else
                    _ = image
                    request.finish(nil)
                    #endif
                }
                // Cancellation can arrive before the request has an id to cancel. `store` says so,
                // and this is the only place that id will ever be seen again.
                if let orphan = request.store(id) { Self.caching.cancelImageRequest(orphan) }
            }
        } onCancel: {
            if let id = request.cancel() { Self.caching.cancelImageRequest(id) }
        }
    }

    // MARK: Caching ahead of the scroll

    func startCachingThumbnails(_ assetIds: [String], maxPixel: Int) {
        let assets = Self.assets(for: assetIds)
        guard !assets.isEmpty else { return }
        let side = CGFloat(maxPixel)
        Self.caching.startCachingImages(
            for: assets,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: Self.thumbnailOptions()
        )
    }

    func stopCachingThumbnails(_ assetIds: [String], maxPixel: Int) {
        let assets = Self.assets(for: assetIds)
        guard !assets.isEmpty else { return }
        let side = CGFloat(maxPixel)
        Self.caching.stopCachingImages(
            for: assets,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: Self.thumbnailOptions()
        )
    }

    func stopCachingAllThumbnails() {
        Self.caching.stopCachingImagesForAllAssets()
    }

    private static func assets(for identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    func imageData(for assetId: String) async throws -> Data {
        guard let asset = Self.asset(for: assetId) else { throw BackfillAssetError.missing }
        let options = PHImageRequestOptions()
        // Same rule as the thumbnail, and here it is the one the picker already enforced by
        // refusing to select a cloud-only asset. This is the backstop, not the gate.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        // The original bytes, whatever they are. `ImagePipeline` owns the conversion to upright
        // JPEG — doing any of it here would be a second pipeline that drifts from the first.
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, info in
                guard resumed.claim() else { return }
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.resume(throwing: inCloud ? BackfillAssetError.notOnDevice : .unreadable)
            }
        }
    }

    private static func asset(for identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
}

/// One-shot latch for a `PHImageManager` callback.
///
/// PhotoKit's result handlers are documented to fire more than once for some delivery modes, and
/// resuming a continuation twice is a crash rather than a warning. The options above ask for a
/// single callback; this makes a second one harmless instead of fatal.
/// One in-flight thumbnail request: its continuation, its `PHImageRequestID`, and the guarantee
/// that exactly one thing ends it.
///
/// Three events race here — PhotoKit's result handler, the task's cancellation, and the closure
/// that is still assembling the request — and a `CheckedContinuation` resumed twice is a crash
/// rather than a warning while one resumed zero times is a task that never ends.
///
/// **Cancellation resumes the continuation itself rather than waiting for PhotoKit to call back.**
/// `cancelImageRequest` is documented to deliver a final cancelled callback, and in practice it
/// does — but a tile whose task can only finish when a callback arrives is a tile that hangs
/// forever if one ever does not, and that is not a risk worth carrying for a picture. Resuming here
/// makes the hang structurally impossible: a later callback finds the request already done and is
/// dropped. The request is still cancelled at PhotoKit, so nothing goes on decoding.
///
/// The awkward case is cancellation arriving *before* the continuation exists, which
/// `withTaskCancellationHandler` permits — `cancel` leaves the request unfinished when it has
/// nothing to resume, and `attach` finishes it the moment it does.
nonisolated final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var id: PHImageRequestID?
    private var done = false
    private var cancelRequested = false

    /// Hand over the continuation, resuming it at once if cancellation already arrived.
    func attach(_ continuation: CheckedContinuation<Data?, Never>) {
        lock.lock()
        if cancelRequested, !done {
            done = true
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Record the request id. Returns it when cancellation got here first, in which case the caller
    /// is the only one who can still cancel it.
    func store(_ newId: PHImageRequestID) -> PHImageRequestID? {
        lock.lock(); defer { lock.unlock() }
        if cancelRequested { return newId }
        id = newId
        return nil
    }

    /// PhotoKit answered. Silent if the request already ended.
    func finish(_ data: Data?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: data)
    }

    /// The task was cancelled. Returns the id still outstanding at PhotoKit, if there is one.
    func cancel() -> PHImageRequestID? {
        lock.lock()
        cancelRequested = true
        let outstanding = id
        id = nil
        var resuming: CheckedContinuation<Data?, Never>?
        // **`done` is only set when there is something to resume.** Setting it unconditionally
        // would tell a later `attach` the request had already finished, and that continuation would
        // never be resumed by anybody — the exact hang this type exists to rule out.
        if !done, let continuation {
            done = true
            resuming = continuation
            self.continuation = nil
        }
        lock.unlock()
        resuming?.resume(returning: nil)
        return outstanding
    }
}

private nonisolated final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
#endif

/// Widening a selected-photos grant, in place.
///
/// **This is not a re-prompt and must never become one.** iOS shows its authorization prompt
/// once, a denial is close to permanent, and `docs/decisions.md` records that this app builds no
/// retry funnel. `presentLimitedLibraryPicker` is a different thing entirely: it is the selection
/// sheet a parent who chose "Selected Photos" can open any number of times to add more, and it
/// asks for no new permission because the grant is already there.
///
/// Setting `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` in `Info.plist` is what makes this
/// the app's job — iOS otherwise volunteers its own version of this alert once per launch, and
/// two things offering the same choice in different words is worse than either alone.
@MainActor
enum LimitedLibraryPicker {

    /// Presents the selection sheet, and returns once it has been dismissed so the caller can
    /// rescan against whatever is now visible.
    ///
    /// Silent where there is no view controller to present from — a missing window is not
    /// something a parent can act on, and this is an offer rather than a promise.
    static func present() async {
        #if canImport(UIKit) && canImport(PhotosUI)
        guard let controller = topViewController() else { return }
        // The async overload resumes when the sheet is dismissed and hands back the identifiers
        // now in the selection. They are discarded here on purpose — the scan re-reads the
        // library rather than trusting a list, so widening and a first grant take one path.
        _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        #endif
    }

    #if canImport(UIKit)
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        // The flow is a full-screen cover over the root, so the thing that must present this is
        // the deepest presented controller rather than the root itself.
        while let presented = top.presentedViewController { top = presented }
        return top
    }
    #endif
}
