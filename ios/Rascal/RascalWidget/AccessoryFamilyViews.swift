import SwiftUI
import WidgetKit

/// The Lock Screen families.
///
/// **Colour does not exist here.** Accessory widgets are rendered as a mask — every colour a view
/// sets is discarded and replaced with one system tint. Terracotta-means-mission and
/// periwinkle-means-question carry real meaning in this product, and on the Lock Screen that
/// channel is simply gone.
///
/// It is replaced with two others, both of which survive a monochrome render:
///
///   * **The symbol.** Each prompt kind already has one on the `PromptCard` — a camera, a
///     waveform, a speech bubble — so the Lock Screen inherits the app's vocabulary instead of
///     inventing a second one. `WidgetSnapshot.Item.symbolName` is the single source for it.
///   * **Hierarchy.** The prompt's own words are set at full strength; the label above it is
///     small caps and secondary. Weight and size are the contrast, in place of hue.
///
/// `.widgetAccentable()` marks the symbol as belonging to the accented group, which is the one
/// distinction the Lock Screen *does* keep when the user has tinted their screen.

// MARK: - Rectangular

/// Three lines beside the clock. The one accessory family with room for a prompt's actual words.
struct RectangularTodayView: View {
    let state: WidgetSnapshotState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch state {
            case .absent:
                label(symbol: "book.closed", text: "Today")
                Text("Open for today's prompts")
                    .font(.system(size: 13))

            case .stale(let name):
                label(symbol: "book.closed", text: name.isEmpty ? "Today" : name)
                Text("Open for today's prompts")
                    .font(.system(size: 13))

            case .current(let snapshot):
                loaded(snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(destination)
    }

    @ViewBuilder
    private func loaded(_ snapshot: WidgetSnapshot) -> some View {
        if snapshot.isComplete {
            label(symbol: "checkmark.circle", text: "Today")
            Text("Both done")
                .font(.system(size: 13, weight: .medium))
        } else if let next = snapshot.nextUp {
            label(symbol: next.item.symbolName, text: next.label)
            // The prompt's own words. This is the only accessory family that can carry them, and
            // it is the reason the Lock Screen is worth supporting at all. Two candidates rather
            // than one: the rectangular slot is about three lines tall, and at accessibility type
            // it is closer to one.
            ViewThatFits(in: .vertical) {
                PromptLine(text: next.item.body, budget: 52)
                PromptLine(text: next.item.body, budget: 34)
                PromptLine(text: next.item.body, budget: 20)
            }
        } else {
            label(symbol: "book.closed", text: "Today")
            Text("Nothing waiting")
                .font(.system(size: 13))
        }
    }

    /// Small caps and a symbol. `widgetAccentable` puts the symbol in the accented group, which
    /// is the one difference a tinted Lock Screen keeps.
    private func label(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .widgetAccentable()
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
        }
        .opacity(0.75)
    }

    private var destination: URL {
        if case .current(let snapshot) = state, let next = snapshot.nextUp {
            return WidgetDeepLink.assignment(next.item.assignmentId).url
        }
        return WidgetDeepLink.today.url
    }
}

// MARK: - Circular

/// A symbol in a ring. There is no room for words, so this family says which *kind* of thing is
/// waiting and nothing else — never how many.
struct CircularTodayView: View {
    let state: WidgetSnapshotState

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .widgetAccentable()
        }
        .widgetURL(destination)
    }

    private var symbol: String {
        switch state {
        case .absent, .stale:
            return "book.closed"
        case .current(let snapshot):
            if snapshot.isComplete { return "checkmark.circle" }
            guard let next = snapshot.nextUp else { return "book.closed" }
            return next.item.symbolName
        }
    }

    private var destination: URL {
        if case .current(let snapshot) = state, let next = snapshot.nextUp {
            return WidgetDeepLink.assignment(next.item.assignmentId).url
        }
        return WidgetDeepLink.today.url
    }
}

// MARK: - Inline

/// One run of text above the clock, and a symbol the system may or may not keep. Shortened on a
/// word boundary like everywhere else, because this is the tightest space of the five.
struct InlineTodayView: View {
    let state: WidgetSnapshotState

    var body: some View {
        Label {
            Text(WidgetNarration.inline(for: state))
        } icon: {
            Image(systemName: symbol)
        }
        .widgetURL(destination)
    }

    private var symbol: String {
        guard case .current(let snapshot) = state else { return "book.closed" }
        if snapshot.isComplete { return "checkmark" }
        return snapshot.nextUp?.item.symbolName ?? "book.closed"
    }

    private var destination: URL {
        if case .current(let snapshot) = state, let next = snapshot.nextUp {
            return WidgetDeepLink.assignment(next.item.assignmentId).url
        }
        return WidgetDeepLink.today.url
    }
}
