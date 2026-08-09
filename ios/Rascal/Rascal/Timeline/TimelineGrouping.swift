import Foundation

/// Cutting the archive into days, and noticing where a year turns over.
///
/// **Everything here reads `occurred_at` and nothing reads `created_at`.** A photo from 2019
/// imported tonight belongs under a day in 2019 — that is the entire reason the two timestamps
/// are separate, and a timeline that groups by "when it was uploaded" is the specific bug this
/// file exists to not have.
///
/// Days come from `Calendar.startOfDay`, not from arithmetic on seconds. A day is 23 hours long
/// twice a year in most of the world, and 25 hours the other time; anything that divides by
/// 86,400 puts a spring-forward evening on the wrong date.
nonisolated enum TimelineGrouping {

    /// One day of the archive, in the order the timeline draws it.
    struct Day<Item>: Identifiable {
        /// Midnight local to `calendar`, which is what makes this a stable group key.
        let start: Date
        let items: [Item]
        /// Set on the first day of a calendar year that differs from the day above it, so the
        /// list can draw a divider there. Nil everywhere else — including on the very first
        /// group, which needs no divider because nothing precedes it.
        let yearDivider: Int?

        var id: Date { start }
    }

    /// Group entries, newest day first, preserving the order they arrive in within each day.
    ///
    /// The input is expected to be sorted newest-first by `occurred_at` — that is how both the
    /// server and the local `@Query` return it — and this does not re-sort. Grouping is
    /// therefore a single pass, which matters on a five-hundred entry list that regroups
    /// whenever SwiftData changes.
    static func days<Item>(
        _ items: [Item],
        calendar: Calendar = .current,
        occurredAt: (Item) -> Date
    ) -> [Day<Item>] {
        var groups: [Day<Item>] = []
        var currentStart: Date?
        var current: [Item] = []

        func flush() {
            guard let start = currentStart, !current.isEmpty else { return }
            groups.append(Day(start: start, items: current, yearDivider: nil))
            current = []
        }

        for item in items {
            let start = calendar.startOfDay(for: occurredAt(item))
            if start != currentStart {
                flush()
                currentStart = start
            }
            current.append(item)
        }
        flush()

        return withYearDividers(groups, calendar: calendar)
    }

    /// Mark the days where the calendar year changes from the day above.
    ///
    /// Deliberately a second pass over the groups rather than a branch inside the first: the
    /// divider is a property of the boundary between two days, and computing it while building
    /// a day means asking about a group that does not exist yet.
    private static func withYearDividers<Item>(
        _ groups: [Day<Item>],
        calendar: Calendar
    ) -> [Day<Item>] {
        var previousYear: Int?
        return groups.map { group in
            let year = calendar.component(.year, from: group.start)
            defer { previousYear = year }
            // Nil on the first group: nothing precedes it, so there is no boundary to mark.
            guard let previousYear, previousYear != year else { return group }
            return Day(start: group.start, items: group.items, yearDivider: year)
        }
    }
}
