import Foundation

/// Which month a backfill is filling, and what `occurred_at` an entry from it gets.
///
/// **This is the defect the whole feature exists to prevent.** A photo from October 2019 filed
/// under this week looks completely normal — a card in the timeline, a plausible date, nothing
/// out of place — and it is wrong permanently. The archive's entire value is that
/// `occurred_at` means when it happened.
///
/// So the fallback here is deliberately *not* the share sheet's. `PendingShare.resolveOccurredAt`
/// falls back to `now`, which is right for a photo being shared this minute and catastrophic for
/// one being backfilled from six years ago. **A backfill falls back to the month it is filling,
/// never to today**, and says which it did.

// MARK: - A month, as a thing you can name

/// A year and a month, with no day, no time, and no timezone.
///
/// Deliberately not a `Date`. A month is a calendar span, and carrying one as an instant is how
/// "October 2019" becomes "2019-10-01T00:00:00Z" and then, one timezone conversion later,
/// September.
nonisolated struct BackfillMonth: Codable, Equatable, Hashable, Sendable, Comparable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = min(max(month, 1), 12)
    }

    init?(containing date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        self.init(year: year, month: month)
    }

    /// The month a `YYYY-MM-DD` calendar day falls in, read straight out of the string.
    ///
    /// **No `Date` and no timezone anywhere in this path, deliberately.** `children.birthdate` is a
    /// calendar day the server named, and the only way to turn one into a month without a zone
    /// deciding the answer is not to build an instant in the first place. Parsing it to a `Date` in
    /// the device's zone and reading the month back in the child's — which is what the obvious
    /// version does — files a child born on the 1st into the previous month for any family living
    /// far enough east, and a child born on the last of a month into the next one going west.
    /// That is the `birthMonth` floor off by one, silently, for exactly the families who travel.
    init?(calendarDay iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return nil }
        self.init(year: parts[0], month: parts[1])
    }

    /// The same calendar month, `years` earlier. Plain arithmetic on two integers — a month is not
    /// an instant, so nothing here can drift across a boundary.
    func subtracting(years: Int) -> BackfillMonth {
        BackfillMonth(year: year - years, month: month)
    }

    /// The month before this one.
    func previous() -> BackfillMonth {
        month == 1
            ? BackfillMonth(year: year - 1, month: 12)
            : BackfillMonth(year: year, month: month - 1)
    }

    static func < (lhs: BackfillMonth, rhs: BackfillMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    /// Stable across launches, so a dismissal recorded today still matches next week.
    var key: String { String(format: "%04d-%02d", year, month) }

    /// **Midday on the 1st, not midnight.** A month's fallback date has to survive being read in
    /// a timezone west of wherever it was written: midnight on the 1st read in UTC-5 is the last
    /// day of the previous month, which would file a backfilled October entry under September and
    /// make the fallback itself the bug it exists to prevent.
    func fallbackDate(calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        components.hour = 12
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    func label(locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: fallbackDate())
    }

    /// "October", with no year. For a list already grouped under one.
    func monthName(locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: fallbackDate())
    }
}

// MARK: - Whose calendar

/// The calendar the browse surface asks "what month is it" in.
///
/// **The child's `family_timezone`, never `Calendar.current`.** This is the `daysUntilExpiry`
/// defect from Phase 11 in a second place: a parent in Auckland browsing an archive whose family
/// timezone is Los Angeles is up to a day ahead, and on the 1st of a month that day is a whole
/// month — so `SUGGESTED` would offer September in earlier years while the child's own calendar
/// still says August, and `EVERY MONTH` would stop one month short. The device's zone is a fact
/// about where the phone is; the archive's months are a fact about the child.
///
/// A zone identifier the system does not know falls back to the device's rather than to UTC.
/// A wrong-but-local answer is off by hours; UTC is off by hours *and* wrong for everyone.
nonisolated enum BackfillCalendar {

    static func family(_ timeZoneIdentifier: String?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = zone
        }
        return calendar
    }

    /// The month `now` falls in, in the child's zone.
    static func month(containing now: Date, in timeZoneIdentifier: String?) -> BackfillMonth? {
        BackfillMonth(containing: now, calendar: family(timeZoneIdentifier))
    }
}

// MARK: - Resolving occurred_at

nonisolated enum BackfillDateRule {

    /// Where a backfilled entry's `occurred_at` came from. Recorded rather than inferred, so the
    /// composer can say it out loud instead of leaving the parent to judge from whether the date
    /// looks plausible.
    enum Source: String, Codable, Sendable, Equatable {
        /// The asset's own creation date. The normal case, and the only one that is exact.
        case assetCreationDate
        /// The asset had no usable date, so the month being backfilled stood in. **Visible in the
        /// UI** — a defaulted date that looks like a real one is the failure mode here.
        case backfilledMonth
    }

    /// `occurred_at` for a selection of assets from one month.
    ///
    /// **The earliest capture date wins**, matching the share sheet: three photos from one
    /// afternoon file the entry on that afternoon, and one of them missing a date does not drag
    /// the entry forward. Where the share sheet then falls back to `now`, this falls back to the
    /// month — never to today, under any circumstance.
    static func resolve(
        creationDates: [Date?],
        month: BackfillMonth,
        calendar: Calendar = .current
    ) -> (date: Date, source: Source) {
        let usable = creationDates.compactMap { $0 }.filter { isPlausible($0, for: month, calendar: calendar) }
        guard let earliest = usable.min() else {
            return (month.fallbackDate(calendar: calendar), .backfilledMonth)
        }
        return (earliest, .assetCreationDate)
    }

    /// **"Clearly invalid" means a date that is not in the month being backfilled.**
    ///
    /// The scan grouped this asset into that month by its creation date, so a date outside it did
    /// not come from the grouping — it came from metadata edited afterwards, a broken import, or
    /// an epoch-zero default. Trusting it would file the entry somewhere neither the parent nor
    /// the scan asked for, and a photo picked out of an October cluster belongs in October.
    static func isPlausible(
        _ date: Date,
        for month: BackfillMonth,
        calendar: Calendar = .current
    ) -> Bool {
        BackfillMonth(containing: date, calendar: calendar) == month
    }
}
