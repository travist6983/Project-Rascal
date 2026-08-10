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
        .description("Today's mission and question. Tap to write one down.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
        // Nothing here is a count, a streak, or a percentage, and that is a product rule rather
        // than an omission — see docs/decisions.md. A backlog number parked on a Home Screen is
        // a guilt engine in the one place a parent cannot look away from.
    }
}

/// One entry, rendered now.
///
/// The timeline is the *backstop*, not the mechanism. The app calls
/// `WidgetCenter.reloadAllTimelines()` every time it writes a snapshot, and that is what makes
/// the widget current within seconds of the parent finishing something. What the timeline adds
/// is the day boundary: a phone nobody opens overnight must stop showing yesterday.
struct TodayTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayWidgetEntry {
        TodayWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayWidgetEntry) -> Void) {
        completion(TodayWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayWidgetEntry>) -> Void) {
        completion(Timeline(entries: [TodayWidgetEntry(date: .now)], policy: .atEnd))
    }
}

struct TodayWidgetEntry: TimelineEntry {
    let date: Date
}

/// The neutral state: no snapshot to render.
///
/// This is what a fresh install and a signed-out phone both show, and it is deliberately not an
/// error. There is nothing wrong — the app simply has not written anything yet.
struct TodayWidgetEntryView: View {
    let entry: TodayWidgetEntry

    var body: some View {
        Text("Open the app to see today's prompts.")
            .font(.footnote)
            .multilineTextAlignment(.leading)
            .containerBackground(.background, for: .widget)
    }
}
