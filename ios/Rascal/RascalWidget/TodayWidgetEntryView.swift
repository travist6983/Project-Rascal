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
            // One element, one sentence — for every family that *has* one tap target. Without it
            // the small family announces five separate labels for something a parent reads in one
            // glance.
            //
            // **`systemMedium` is excluded, and that is the accessible choice rather than an
            // oversight.** It draws each prompt as its own `Link`; collapsing the widget would
            // hide both from VoiceOver, leaving a sighted parent able to open the question
            // directly and a VoiceOver user able only to open the app. Its rows carry their own
            // sentences instead — see `MediumTodayView`.
            .accessibilityElement(children: family == .systemMedium ? .contain : .ignore)
            .accessibilityLabel(
                family == .systemMedium
                    ? ""
                    : (family == .accessoryInline
                        ? WidgetNarration.inline(for: entry.state)
                        : WidgetNarration.sentence(for: entry.state))
            )
            // **Exactly one `widgetURL` in the whole widget, and it has to be here.**
            //
            // Apple's contract is explicit: if more than one view applies `widgetURL`, the
            // behaviour is *undefined* — not last-wins, not innermost-wins. The first version of
            // this file set a fallback here and a per-family one inside each view, which is two,
            // and on `systemSmall` and all three accessory families that is undefined behaviour
            // shipped as a tap target. Every family's destination is now resolved in one place.
            //
            // `systemMedium` is the exception and is allowed to be: it uses `Link` per row, which
            // *is* supported there, so this is the floor under the rows rather than a second
            // destination competing with them.
            .widgetURL(destination)
    }

    /// Where a tap lands, per family.
    ///
    /// The families that draw one thing send you to that thing. `systemMedium` draws two and
    /// wires each as its own `Link`, so a tap that misses both is a tap on the widget in general
    /// — Today is the honest answer, not a guess at which of the two was meant.
    private var destination: URL {
        guard family != .systemMedium,
              case .current(let snapshot) = entry.state,
              let next = snapshot.nextUp
        else { return WidgetDeepLink.today.url }
        return WidgetDeepLink.assignment(next.item.assignmentId).url
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
