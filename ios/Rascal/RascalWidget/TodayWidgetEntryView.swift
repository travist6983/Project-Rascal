import SwiftUI
import WidgetKit

/// Picks the rendering for the family the system asked for, and does the three things every
/// family needs identically: resolve the palette, paint the container, and collapse the whole
/// widget into one accessibility element that reads as a sentence.
struct TodayWidgetEntryView: View {
    let entry: TodayWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .environment(\.palette, WidgetPalette.resolved(for: scheme))
            .containerBackground(for: .widget) { background }
            // One element, one sentence. Without this the small family announces five separate
            // labels for something a parent reads in one glance.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                family == .accessoryInline
                    ? WidgetNarration.inline(for: entry.state)
                    : WidgetNarration.sentence(for: entry.state)
            )
            // Every family opens the app. Which assignment depends on what is on screen, so the
            // per-item links live in the views; this is the floor under them, and the reason a
            // tap on the empty half of a widget still lands somewhere real.
            .widgetURL(WidgetDeepLink.today.url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            SmallTodayView(state: entry.state)
        case .systemMedium:
            MediumTodayView(state: entry.state)
        case .accessoryRectangular:
            RectangularTodayView(state: entry.state)
        case .accessoryCircular:
            CircularTodayView(state: entry.state)
        case .accessoryInline:
            InlineTodayView(state: entry.state)
        default:
            // A family this build does not know about. Rendering the rectangular layout is
            // better than rendering nothing: it is the most adaptable of the five.
            RectangularTodayView(state: entry.state)
        }
    }

    /// Accessory families are drawn onto the Lock Screen's own material and must not paint their
    /// own ground — `AccessoryWidgetBackground` is the system's, and a solid fill there is the
    /// thing that makes a Lock Screen widget look pasted on.
    @ViewBuilder
    private var background: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            AccessoryWidgetBackground()
        default:
            WidgetPalette.resolved(for: scheme).canvas
        }
    }
}
