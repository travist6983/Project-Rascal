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
