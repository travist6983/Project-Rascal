import Foundation

/// Finding months with photos and no entries.
///
/// **Not an assignment, and it must never become one.** The server owns the schedule; a backfill
/// suggestion depends on what is in *this* phone's camera roll, which the server cannot know. So
/// this never occupies a slot, never creates an `assignments` row, and the entries it produces
/// carry `assignment_id` null — freeform entries are first-class and this is what that is for.
/// If you find yourself minting an assignment here, that is the rule breaking.
///
/// The scan is split in two so the part worth testing has no PhotoKit in it:
/// :func:`BackfillPlan.clusters` is pure — asset dates and entry dates in, months out — and
/// `PhotoLibraryBackfillSource` is the thin part that asks PhotoKit for those dates.

// MARK: - What a cluster is

nonisolated struct BackfillCluster: Equatable, Sendable, Identifiable {
    let month: BackfillMonth
    /// How many assets the scan could actually see and read.
    let assetCount: Int
    /// Assets in this month that live only in iCloud. Counted separately because presenting one
    /// as available and then failing to load it is worse than saying so up front.
    let cloudOnlyCount: Int

    var id: String { month.key }
}

// MARK: - The pure half

nonisolated enum BackfillPlan {

    /// Months that have photos and no entries, newest first.
    ///
    /// `entryDates` is every `occurred_at` this device holds. Compared locally and never by
    /// asking the server — the server has no idea what is in this camera roll, and a round trip
    /// per month would make a 40,000-asset library unusable.
    static func clusters(
        assetDates: [Date],
        cloudOnlyDates: [Date] = [],
        entryDates: [Date],
        dismissed: Set<String> = [],
        calendar: Calendar = .current,
        minimumAssets: Int = 3
    ) -> [BackfillCluster] {
        let occupied = Set(entryDates.compactMap { BackfillMonth(containing: $0, calendar: calendar) })

        var counts: [BackfillMonth: Int] = [:]
        for date in assetDates {
            guard let month = BackfillMonth(containing: date, calendar: calendar) else { continue }
            counts[month, default: 0] += 1
        }
        var cloudCounts: [BackfillMonth: Int] = [:]
        for date in cloudOnlyDates {
            guard let month = BackfillMonth(containing: date, calendar: calendar) else { continue }
            cloudCounts[month, default: 0] += 1
            counts[month, default: 0] += 1
        }

        return counts
            .filter { month, count in
                // A month with one stray photo is not a month you failed to write up.
                count >= minimumAssets
                    && !occupied.contains(month)
                    && !dismissed.contains(month.key)
            }
            .map { month, count in
                BackfillCluster(
                    month: month, assetCount: count, cloudOnlyCount: cloudCounts[month] ?? 0
                )
            }
            // Newest first: the month a parent is likeliest to still remember.
            .sorted { $0.month > $1.month }
    }
}

// MARK: - Dismissal

/// A month the parent waved away. **It stays dismissed.**
nonisolated protocol BackfillDismissalStoring: AnyObject, Sendable {
    func dismissed() -> Set<String>
    func dismiss(_ month: BackfillMonth)
}

nonisolated final class UserDefaultsBackfillDismissalStore: BackfillDismissalStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "backfill.dismissedMonths") {
        self.defaults = defaults
        self.key = key
    }

    func dismissed() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func dismiss(_ month: BackfillMonth) {
        var current = dismissed()
        current.insert(month.key)
        defaults.set(Array(current).sorted(), forKey: key)
    }
}

nonisolated final class InMemoryBackfillDismissalStore: BackfillDismissalStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var months: Set<String>

    init(_ months: Set<String> = []) { self.months = months }

    func dismissed() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return months
    }

    func dismiss(_ month: BackfillMonth) {
        lock.lock(); defer { lock.unlock() }
        months.insert(month.key)
    }
}

// MARK: - The cached result

/// What a completed scan produced, and when.
///
/// Cached because re-reading 40,000 assets on every launch is not acceptable. Keyed on the
/// library's own change token where one is available, so the cache is invalidated by the library
/// changing rather than by a timer guessing that it might have.
nonisolated struct BackfillScanResult: Codable, Equatable, Sendable {
    let clusters: [StoredCluster]
    let scannedAt: Date
    /// Opaque. `nil` where the platform gave us nothing to key on, which means the cache falls
    /// back to its age alone.
    let libraryToken: String?

    nonisolated struct StoredCluster: Codable, Equatable, Sendable {
        let year: Int
        let month: Int
        let assetCount: Int
        let cloudOnlyCount: Int
    }

    var asClusters: [BackfillCluster] {
        clusters.map {
            BackfillCluster(
                month: BackfillMonth(year: $0.year, month: $0.month),
                assetCount: $0.assetCount,
                cloudOnlyCount: $0.cloudOnlyCount
            )
        }
    }

    static func from(_ clusters: [BackfillCluster], at date: Date, token: String?) -> BackfillScanResult {
        BackfillScanResult(
            clusters: clusters.map {
                StoredCluster(
                    year: $0.month.year,
                    month: $0.month.month,
                    assetCount: $0.assetCount,
                    cloudOnlyCount: $0.cloudOnlyCount
                )
            },
            scannedAt: date,
            libraryToken: token
        )
    }

    func isFresh(now: Date, token: String?, maximumAge: TimeInterval = 60 * 60 * 24) -> Bool {
        if let libraryToken, let token { return libraryToken == token }
        return now.timeIntervalSince(scannedAt) < maximumAge
    }
}

// MARK: - Authorization

/// What the parent granted. **Limited is a legitimate state, not an error.**
///
/// iOS lets someone grant access to selected photos only. Treating that as a failure would put an
/// error on screen for a parent who made a deliberate, reasonable choice — so the scan runs over
/// what it can see and the UI says that is what it is doing.
nonisolated enum BackfillAuthorization: Equatable, Sendable {
    case authorized
    case limited
    case denied
    case notDetermined

    var canScan: Bool { self == .authorized || self == .limited }
}
