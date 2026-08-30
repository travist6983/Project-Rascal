import Foundation

/// What the parent has picked out of one month, and the rule that keeps the date honest.
///
/// **A selection belongs to exactly one day.** `BackfillDateRule` resolves a set of assets to the
/// earliest plausible creation date among them, so a selection spread across three weeks produces
/// a date that is defensible and not accurate: the entry lands on the first of those weeks and
/// says nothing about the rest. Confining a selection to a single day makes the resolved date
/// *exact*, which is the only reason this feature is careful about `occurred_at` at all.
///
/// Lifted out of the picker's `@State` so the rule can be asserted rather than eyeballed — the
/// failure it prevents is invisible once shipped.
nonisolated struct BackfillSelection: Equatable {
    private(set) var assetIds: Set<String> = []
    /// The day the selection belongs to. Nil when nothing is picked.
    private(set) var day: Date?
    /// A day the parent reached for while holding a selection on another one.
    ///
    /// Held rather than acted on: the picker explains the rule at the point it is met instead of
    /// silently refusing the tap, and instead of silently discarding what is already picked.
    private(set) var blockedDay: Date?

    var isEmpty: Bool { assetIds.isEmpty }
    var count: Int { assetIds.count }

    func contains(_ asset: BackfillAsset) -> Bool { assetIds.contains(asset.id) }

    /// Tap a tile.
    ///
    /// A cloud-only asset is not selectable — it cannot become an entry without a download, and
    /// this feature does not download.
    mutating func tap(_ asset: BackfillAsset, on day: Date) {
        guard asset.isSelectable else { return }

        if let current = self.day, current != day {
            blockedDay = day
            return
        }

        blockedDay = nil
        if assetIds.contains(asset.id) {
            assetIds.remove(asset.id)
            if assetIds.isEmpty { self.day = nil }
        } else {
            assetIds.insert(asset.id)
            self.day = day
        }
    }

    /// Keep only what is still on the grid **and still on this selection's own day**.
    ///
    /// **The day is the point, and passing month-wide ids here was a hole in the one-day rule.**
    /// Two things can move a selected photo out from under a selection while the picker is open. A
    /// grant that narrows removes it outright — revoking a shared photo in Settings, or dropping
    /// from full access to a selection — and without this the Use pill counts photos that are no
    /// longer on the grid. But Photos' *Adjust Date & Time* moves a photo to a **different day in
    /// the same month**, and against a month-wide set that photo is still "available": it stays
    /// selected while the grid regroups it under another header, and `use()` then hands
    /// `BackfillDateRule` two days' worth of dates and files the entry under the earlier one.
    ///
    /// That is exactly the spread this type exists to prevent — *"a selection spread across three
    /// weeks produces a date that is defensible and not accurate"* — so the caller passes the ids
    /// on `day`, not the ids in the month.
    mutating func retain(_ available: Set<String>) {
        let kept = assetIds.intersection(available)
        guard kept != assetIds else { return }
        assetIds = kept
        if assetIds.isEmpty {
            day = nil
            blockedDay = nil
        }
    }

    /// "Start here" — abandon what is picked and begin on the day just reached for.
    ///
    /// Deliberately clears rather than moves. The photos picked on the old day are not the same
    /// moment as the ones on the new one, and carrying them across is the spread this type exists
    /// to prevent.
    mutating func startOver() {
        assetIds = []
        day = nil
        blockedDay = nil
    }
}
