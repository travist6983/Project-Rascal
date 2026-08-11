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

/// A month as the "Every month" browse list shows it.
///
/// Different from a `BackfillCluster` on purpose. A cluster is an *offer* — a month worth
/// suggesting, filtered by the minimum count and by what the parent has already written or waved
/// away. This is just a fact: here is a month, here is what is in it. Every month with a photo
/// appears, including the ones already written about and the ones holding a single stray picture,
/// because a browse list that hides months is a browse list a parent cannot trust.
nonisolated struct BackfillMonthSummary: Equatable, Sendable, Identifiable {
    let month: BackfillMonth
    let assetCount: Int
    /// Entries this device holds with an `occurred_at` in this month.
    let entryCount: Int

    var id: String { month.key }
    var isLogged: Bool { entryCount > 0 }
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

    /// Every month that holds a photo, with what is in it and what has been written about it.
    ///
    /// This is the browse list behind "Every month", and it deliberately applies **none** of
    /// `clusters`' filters: no minimum count, no exclusion of months already written about, no
    /// dismissals. A parent who set October aside still expects to find October here — that is
    /// what the toast means by "it's still in Every month" — and a month with two photos is still
    /// a month they may want to wander back through.
    ///
    /// Newest first, same as `clusters`.
    static func monthIndex(
        assetDates: [Date],
        cloudOnlyDates: [Date] = [],
        entryDates: [Date],
        calendar: Calendar = .current
    ) -> [BackfillMonthSummary] {
        var assets: [BackfillMonth: Int] = [:]
        for date in assetDates + cloudOnlyDates {
            guard let month = BackfillMonth(containing: date, calendar: calendar) else { continue }
            assets[month, default: 0] += 1
        }

        var entries: [BackfillMonth: Int] = [:]
        for date in entryDates {
            guard let month = BackfillMonth(containing: date, calendar: calendar) else { continue }
            entries[month, default: 0] += 1
        }

        // Keyed off the photos, not off the entries. A month with entries and no photos is not a
        // month you can browse a camera roll for, and listing it under "Every month" would offer
        // a door onto an empty room.
        return assets
            .map { month, count in
                BackfillMonthSummary(
                    month: month, assetCount: count, entryCount: entries[month] ?? 0
                )
            }
            .sorted { $0.month > $1.month }
    }
}

// MARK: - Dismissal

/// A month the parent waved away. **It stays dismissed.**
nonisolated protocol BackfillDismissalStoring: AnyObject, Sendable {
    func dismissed() -> Set<String>
    func dismiss(_ month: BackfillMonth)
    /// Undo a dismissal. Backs the toast's Undo and nothing else.
    func restore(_ month: BackfillMonth)
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

    func restore(_ month: BackfillMonth) {
        var current = dismissed()
        current.remove(month.key)
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

    func restore(_ month: BackfillMonth) {
        lock.lock(); defer { lock.unlock() }
        months.remove(month.key)
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
    /// The browse list behind "Every month".
    ///
    /// **Optional so a cache written before this existed still decodes.** A non-optional field
    /// would fail the decode, and `load()` swallows that as a cache miss — which is a full rescan
    /// of the library on the next launch after an update, for every user, silently. Absent here
    /// means "written by an older build", and the next scan fills it in.
    var months: [StoredMonth]?

    nonisolated struct StoredCluster: Codable, Equatable, Sendable {
        let year: Int
        let month: Int
        let assetCount: Int
        let cloudOnlyCount: Int
    }

    nonisolated struct StoredMonth: Codable, Equatable, Sendable {
        let year: Int
        let month: Int
        let assetCount: Int
        let entryCount: Int
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

    var asMonths: [BackfillMonthSummary] {
        (months ?? []).map {
            BackfillMonthSummary(
                month: BackfillMonth(year: $0.year, month: $0.month),
                assetCount: $0.assetCount,
                entryCount: $0.entryCount
            )
        }
    }

    static func from(
        _ clusters: [BackfillCluster],
        months: [BackfillMonthSummary] = [],
        at date: Date,
        token: String?
    ) -> BackfillScanResult {
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
            libraryToken: token,
            months: months.map {
                StoredMonth(
                    year: $0.month.year,
                    month: $0.month.month,
                    assetCount: $0.assetCount,
                    entryCount: $0.entryCount
                )
            }
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
