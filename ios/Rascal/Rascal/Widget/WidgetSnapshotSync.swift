import SwiftData
import SwiftUI

/// Keeps the widget's snapshot in step with the board, from somewhere that is always on screen.
///
/// **It is a zero-size view because it has to outlive the Today tab.** The publishing used to hang
/// off `TodayScreen`, which reads well until you notice that `RootView` selects tabs with a
/// `switch` — so Today is destroyed the moment the parent taps Timeline, and with it every
/// `@Query` that would have noticed the archive changing.
///
/// The flow that exposes it is not exotic, it is the one `docs/decisions.md` calls week one:
/// *"wrong photo, redo it"*. Deleting an entry releases its assignment, and a delete happens on
/// Entry Detail — two tabs away from Today. The board would go back to "not done" while the file
/// in the App Group still said done, so the Home Screen kept a completion check on a prompt with
/// nothing behind it, and tapping it did nothing, until the parent next opened Today.
///
/// Mounted in `RootView`'s root `ZStack`, so it observes the archive for the whole session
/// regardless of which tab is showing.
struct WidgetSnapshotSync: View {
    let model: TodayModel
    let familyTimezone: String
    var widget: WidgetSnapshotPublisher = .live

    /// The same two queries Today merges, for the same reason: a completion — or its removal — is
    /// a fact about SwiftData, and this has to see it without waiting for a refetch.
    @Query(filter: #Predicate<Entry> { $0.deletedAt == nil }) private var entries: [Entry]
    @Query(filter: #Predicate<Media> { $0.deletedAt == nil }) private var media: [Media]

    /// Nil until the server has answered once.
    ///
    /// **Nil never clears the snapshot**, and that distinction is the whole reason `publish` is
    /// not called with it directly: a refetch that fails leaves the previous board on screen and
    /// must leave the previous widget alone too. Only signing out clears.
    private var snapshot: WidgetSnapshot? {
        guard case .loaded(let response) = model.state else { return nil }
        return WidgetSnapshotBuilder.snapshot(
            from: TodayBoard.merge(response: response, entries: entries, media: media),
            familyTimezone: familyTimezone
        )
    }

    var body: some View {
        // `Color.clear` at zero size: this draws nothing and is here only to hold the queries and
        // the observer.
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: snapshot, initial: true) { _, snapshot in
                guard let snapshot else { return }
                widget.publish(snapshot)
            }
    }
}
