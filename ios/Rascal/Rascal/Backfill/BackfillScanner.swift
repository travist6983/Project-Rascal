import Foundation

#if canImport(Photos)
import Photos
#endif

/// Where the asset dates come from. The seam that keeps PhotoKit out of every assertion.
nonisolated protocol BackfillAssetSource: Sendable {
    func authorization() async -> BackfillAuthorization
    /// Every asset's creation date, and which of them are not on the device.
    ///
    /// **Incremental and cancellable.** Implementations must check `Task.isCancelled` as they go
    /// and must never run on the main thread — a library with 40,000 assets in it would otherwise
    /// block the app for seconds.
    func creationDates() async throws -> (onDevice: [Date], cloudOnly: [Date])
    /// Opaque token that changes when the library does, for cache invalidation. `nil` when the
    /// platform offers none.
    func libraryToken() async -> String?
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
    /// True when the parent granted access to selected photos only. **Not an error** — the UI
    /// says what it can see rather than pretending it saw everything.
    private(set) var isLimitedLibrary = false

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
    }

    /// `entryDates` is every `occurred_at` this device holds, read from the local store by the
    /// caller. Compared locally and never by asking the server.
    func scan(entryDates: [Date], now: Date = Date(), force: Bool = false) {
        task?.cancel()
        task = Task { await run(entryDates: entryDates, now: now, force: force) }
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
        let authorization = await source.authorization()
        guard authorization.canScan else {
            state = .unavailable
            return
        }
        isLimitedLibrary = authorization == .limited

        let token = await source.libraryToken()
        if !force, let cached = cache.load(), cached.isFresh(now: now, token: token) {
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

        let clusters = BackfillPlan.clusters(
            assetDates: dates.onDevice,
            cloudOnlyDates: dates.cloudOnly,
            entryDates: entryDates,
            dismissed: dismissals.dismissed()
        )
        guard !Task.isCancelled else {
            state = .idle
            return
        }
        cache.save(BackfillScanResult.from(clusters, at: now, token: token))
        state = .ready(clusters)
    }

    /// A dismissed month stays dismissed, including against a cached result written before it
    /// was dismissed.
    private func filtered(_ clusters: [BackfillCluster]) -> [BackfillCluster] {
        let dismissed = dismissals.dismissed()
        return clusters.filter { !dismissed.contains($0.month.key) }
    }

    func dismiss(_ month: BackfillMonth) {
        dismissals.dismiss(month)
        if case .ready(let clusters) = state {
            state = .ready(clusters.filter { $0.month != month })
        }
    }
}

// MARK: - Caching

nonisolated protocol BackfillScanCaching: Sendable {
    func load() -> BackfillScanResult?
    func save(_ result: BackfillScanResult)
}

nonisolated struct UserDefaultsBackfillScanCache: BackfillScanCaching {
    private let defaults: UserDefaults
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
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
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
}
#endif
