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
/// **Refresh budget is limited and out of this code's control, so the day boundary is not left
/// to it.** A timeline entry's state is frozen when the timeline is built, so a widget built at
/// 9pm would still say "today" at 1am if the only thing turning it over were a refresh the system
/// is free to delay or drop. `WidgetTimelinePlan` therefore emits a *second* entry, dated the
/// child's midnight and pre-computed as stale — a scheduled entry renders without the system
/// having to grant anything. The refresh request on top of it is what brings new prompts in.
struct TodayTimelineProvider: TimelineProvider {

    /// **No injection seams here, deliberately.** They were tried, and they were a lie: nothing
    /// can construct a `TimelineProvider` except WidgetKit, so a closure nobody ever replaces is
    /// dead weight that reads like a test hook. Everything worth asserting on moved into
    /// `WidgetTimelinePlan`, which is a value type the suite can drive directly. What is left here
    /// is two reads and a mapping.
    private let store = WidgetSnapshotStore.shared

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
                state: context.isPreview ? .current(.preview) : store.state(now: .now)
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayWidgetEntry>) -> Void) {
        let now = Date.now
        let plan = WidgetTimelinePlan.make(
            state: store.state(now: now),
            zone: store.refreshZone(),
            now: now
        )

        completion(
            Timeline(
                entries: plan.entries.map { TodayWidgetEntry(date: $0.date, state: $0.state) },
                policy: .after(plan.refresh)
            )
        )
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
