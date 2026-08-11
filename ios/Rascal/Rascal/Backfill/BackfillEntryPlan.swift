import Foundation

/// What a backfill selection becomes when the parent taps through to the composer.
///
/// **A backfill is not an assignment, and this type is where that is enforced rather than
/// remembered.** The server owns the schedule; a suggestion built from this phone's camera roll
/// is something the server cannot know about. So a backfill never occupies a `question`,
/// `mission`, `weekly` or `monthly` slot, never creates an `assignments` row, and the entry it
/// produces carries `assignment_id` null — freeform entries are first-class and this is exactly
/// what that is for.
///
/// The rule is structural here: this type **has no field that can hold an assignment**, so the
/// composer request it builds cannot carry one. A rule enforced by a missing field cannot be
/// broken by someone forgetting it.
nonisolated struct BackfillEntryPlan: Equatable, Sendable {
    /// The month the parent was invited to fill. Also the `occurred_at` fallback.
    let month: BackfillMonth
    /// Resolved before the composer opens, so the date is on screen before anything is saved.
    let occurredAt: Date
    let occurredAtSource: BackfillDateRule.Source
    let assetCount: Int

    /// **One entry per selection**, matching the share sheet's one-entry-per-share rule.
    init(month: BackfillMonth, creationDates: [Date?], calendar: Calendar = .current) {
        let resolved = BackfillDateRule.resolve(
            creationDates: creationDates, month: month, calendar: calendar
        )
        self.month = month
        self.occurredAt = resolved.date
        self.occurredAtSource = resolved.source
        self.assetCount = creationDates.count
    }

    /// Whether the date on screen was read off the assets or defaulted.
    ///
    /// **The fallback is visible.** A defaulted date rendered identically to a real one is how a
    /// parent ends up trusting a date nothing actually knew.
    var isDateDefaulted: Bool { occurredAtSource == .backfilledMonth }

    /// A small default. Three is the framing, not a hard limit — but forty photos in one entry
    /// is a failure of the interaction rather than a power feature.
    static let suggestedSelectionCount = 3
}

#if canImport(SwiftUI)
import SwiftUI

extension BackfillEntryPlan {
    /// The composer request for this plan.
    ///
    /// `assignment: nil`, always, and it is not a parameter — see the type's note. The mode is
    /// `media` because a backfill is by definition a set of photos.
    func composerRequest(childId: UUID) -> ComposerRequest {
        ComposerRequest(childId: childId, assignment: nil, mode: .media)
    }
}
#endif
