import Foundation

/// One photo in a month being backfilled.
///
/// The scan itself never needs this — it reads dates and counts and produces months. This is what
/// the *picker* needs, and it arrives only once the parent has asked to look at a specific month.
/// The ordering matters: nothing identifies an individual photo until someone has chosen to browse
/// one month, and even then the identifier goes no further than this device.
nonisolated struct BackfillAsset: Equatable, Sendable, Identifiable {
    /// `PHAsset.localIdentifier`. Local to this device and this library — it is not a stable
    /// global name for a photo and is never persisted or sent anywhere.
    let id: String
    /// The asset's own creation date. Optional because a broken import genuinely may not have
    /// one, and `BackfillDateRule` is built to take `[Date?]` for exactly that reason.
    let creationDate: Date?
    /// False when the asset lives only in iCloud.
    ///
    /// **Presented as unavailable rather than fetched.** Downloading a photo would be the one
    /// thing this feature promises not to do — the permission explainer says everything stays on
    /// the phone — and a tile that loads after a silent multi-megabyte download is worse than one
    /// that says plainly it is not here.
    let isOnDevice: Bool

    /// A cloud-only asset cannot become an entry, so it cannot be picked.
    var isSelectable: Bool { isOnDevice }
}

extension BackfillAsset {
    /// The day this asset belongs to, for the picker's day grouping.
    ///
    /// Nil when the asset has no creation date. Such an asset has no day to sit under and the
    /// picker drops it rather than inventing one — its date is exactly what the month fallback
    /// exists to handle, and guessing a day here would launder a missing date into a real-looking
    /// one before `BackfillDateRule` ever sees it.
    func day(calendar: Calendar = .current) -> Date? {
        creationDate.map { calendar.startOfDay(for: $0) }
    }
}
