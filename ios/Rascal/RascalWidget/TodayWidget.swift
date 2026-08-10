import SwiftUI
import WidgetKit

/// Today's mission and question, on the Home Screen and the Lock Screen.
///
/// **The widget reads a file. It never calls the API.** The app writes a small snapshot into the
/// shared App Group container whenever the Today board changes, and this renders whatever is
/// there. That is a deliberate architectural boundary rather than a shortcut: a token refresh
/// running inside an extension, concurrently with the app, can invalidate the app's own session,
/// and the resulting logout is intermittent and miserable to trace back to its cause.
///
/// **No configuration intent.** One child, no options.
struct TodayWidget: Widget {
    static let kind = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TodayTimelineProvider()) { entry in
            TodayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's mission and question. Tap one to write it down.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
        // Nothing here counts anything, and that is a product rule rather than an omission — see
        // `docs/decisions.md`. No backlog number, no streak, no progress ring, no percentage. A
        // count of what is waiting, parked on a Home Screen, is a guilt engine in the one place a
        // parent cannot look away from.
    }
}

// MARK: - The entry

struct TodayWidgetEntry: TimelineEntry {
    let date: Date
    let state: WidgetSnapshotState
}

// MARK: - The provider

/// Reads the snapshot, renders now, and asks to be woken at the child's midnight.
///
/// **The timeline is the backstop, not the mechanism.** The app calls
/// `WidgetCenter.reloadAllTimelines()` every time it writes a snapshot, which is what makes the
/// widget agree with the screen the parent just left, within seconds. What a timeline adds is the
/// day boundary — a phone nobody picks up overnight has to stop showing yesterday on its own.
///
/// Refresh budget is limited and out of this code's control, so nothing here is designed as
/// though frequent refreshes were available: one entry, one wake-up, and a staleness check that
/// runs at render time rather than depending on having been refreshed recently.
struct TodayTimelineProvider: TimelineProvider {

    /// Injected so the gallery previews below can supply their own state without an App Group.
    var read: (Date) -> WidgetSnapshotState = { WidgetSnapshotStore.shared.state(now: $0) }

    /// The grey skeleton the system draws while it waits.
    ///
    /// Realistic content on purpose: a placeholder with empty frames tells a parent nothing about
    /// what they are adding, and the gallery is the one chance the widget gets to explain itself.
    func placeholder(in context: Context) -> TodayWidgetEntry {
        TodayWidgetEntry(date: .now, state: .current(.preview))
    }

    /// What the gallery shows. Same reasoning as `placeholder`.
    func getSnapshot(in context: Context, completion: @escaping (TodayWidgetEntry) -> Void) {
        completion(
            TodayWidgetEntry(
                date: .now,
                state: context.isPreview ? .current(.preview) : read(.now)
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayWidgetEntry>) -> Void) {
        let now = Date.now
        let state = read(now)
        let entry = TodayWidgetEntry(date: now, state: state)

        completion(Timeline(entries: [entry], policy: .after(refreshDate(after: now, given: state))))
    }

    /// The child's next local midnight, when a current snapshot becomes a stale one.
    ///
    /// Falls back to an hour when there is no snapshot to take a zone from. An hour rather than a
    /// minute because the budget is finite and there is nothing to see: the app writing anything
    /// at all will reload this long before the fallback matters.
    private func refreshDate(after now: Date, given state: WidgetSnapshotState) -> Date {
        guard case .current(let snapshot) = state,
              let midnight = snapshot.nextMidnight(after: now)
        else {
            return now.addingTimeInterval(60 * 60)
        }
        return midnight
    }
}

// MARK: - Preview content

extension WidgetSnapshot {
    /// The gallery's example. Real prompts from the seeded library rather than lorem ipsum, and a
    /// generic first name — the gallery is seen before onboarding, so it cannot know a real one.
    ///
    /// Dated today in the device's own zone, so it stays `.current` if anything ever resolves it
    /// rather than quietly becoming an example of the stale state.
    static var preview: WidgetSnapshot { WidgetSnapshot(
        assignedOn: day(for: .now, in: .current),
        familyTimezone: TimeZone.current.identifier,
        childFirstName: "Sam",
        mission: Item(
            assignmentId: UUID(),
            body: "Photograph the thing he carries everywhere right now.",
            kind: "photo",
            isDone: false
        ),
        question: Item(
            assignmentId: UUID(),
            body: "What did he say today that you want to remember?",
            kind: "question",
            isDone: false
        )
    ) }
}
