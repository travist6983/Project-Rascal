import SwiftUI
import WidgetKit

// MARK: - Small

/// One prompt, in full, and a quiet line for the other.
///
/// **The small family leads rather than lists.** There is room for one prompt a parent can
/// actually read and one line saying the other exists; two half-prompts is two things nobody can
/// read. The lead is the first unfinished one, mission before question, so the widget answers
/// "what now" rather than "what is outstanding" — the second is a backlog, and this product does
/// not show backlogs.
struct SmallTodayView: View {
    let state: WidgetSnapshotState

    @Environment(\.palette) private var palette

    var body: some View {
        switch state {
        case .absent:
            NeutralView(name: nil)
        case .stale(let name):
            NeutralView(name: name)
        case .current(let snapshot):
            loaded(snapshot)
        }
    }

    @ViewBuilder
    private func loaded(_ snapshot: WidgetSnapshot) -> some View {
        if snapshot.isEmpty {
            NeutralView(name: snapshot.childFirstName)
        } else if snapshot.isComplete {
            CompleteView(name: snapshot.childFirstName)
        } else if let next = snapshot.nextUp {
            let other = other(than: next, in: snapshot)

            // Give things up in order: prompt length first, then the footer that names the other
            // prompt. The footer goes last because it is the only thing telling a parent the
            // second prompt exists at all.
            ViewThatFits(in: .vertical) {
                layout(next, other: other, budget: 72)
                layout(next, other: other, budget: 52)
                layout(next, other: other, budget: 36)
                layout(next, other: nil, budget: 36)
                layout(next, other: nil, budget: 24)
                layout(next, other: nil, budget: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The lead prompt is what a tap opens. `widgetURL` covers the whole widget on the
            // Home Screen, so this is the tap target rather than one of several.
            .widgetURL(WidgetDeepLink.assignment(next.item.assignmentId).url)
        }
    }

    private func layout(
        _ next: WidgetSnapshot.Featured,
        other: WidgetSnapshot.Featured?,
        budget: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SlotLabel(
                label: next.label,
                symbol: next.item.symbolName,
                tint: tint(for: next.label)
            )

            PromptLine(text: next.item.body, budget: budget)
                .foregroundStyle(palette.ink)

            Spacer(minLength: 0)

            if let other { footer(other) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The other prompt, named and stated — never counted.
    private func footer(_ other: WidgetSnapshot.Featured) -> some View {
        SlotLabel(
            label: other.item.isDone ? "\(other.label) done" : "\(other.label) waiting",
            symbol: other.item.symbolName,
            tint: other.item.isDone ? palette.done : palette.inkMuted,
            isDone: other.item.isDone
        )
    }

    private func other(
        than featured: WidgetSnapshot.Featured,
        in snapshot: WidgetSnapshot
    ) -> WidgetSnapshot.Featured? {
        [snapshot.missionFeatured, snapshot.questionFeatured]
            .compactMap { $0 }
            .first { $0.label != featured.label }
    }

    private func tint(for label: String) -> Color {
        label == "Question" ? palette.question : palette.mission
    }
}

// MARK: - Medium

/// Both prompts, each in its own right — for as long as both fit.
///
/// At accessibility type they do not, and the fallbacks below say what gets given up: the child's
/// name, then prompt length, and finally the second prompt's words, which become the same
/// one-line note the small family uses. What never happens is a prompt cut mid-word or a layout
/// that overflows the widget.
struct MediumTodayView: View {
    let state: WidgetSnapshotState

    @Environment(\.palette) private var palette

    var body: some View {
        switch state {
        case .absent:
            NeutralView(name: nil)
        case .stale(let name):
            NeutralView(name: name)
        case .current(let snapshot):
            loaded(snapshot)
        }
    }

    @ViewBuilder
    private func loaded(_ snapshot: WidgetSnapshot) -> some View {
        if snapshot.isEmpty {
            NeutralView(name: snapshot.childFirstName)
        } else if snapshot.isComplete {
            CompleteView(name: snapshot.childFirstName, roomy: true)
        } else {
            ViewThatFits(in: .vertical) {
                pair(snapshot, budget: 88, showsName: true)
                pair(snapshot, budget: 88, showsName: false)
                pair(snapshot, budget: 60, showsName: false)
                pair(snapshot, budget: 40, showsName: false)
                pair(snapshot, budget: 24, showsName: false)
                lead(snapshot, budget: 40)
                lead(snapshot, budget: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Both prompts, each its own tap target.
    private func pair(_ snapshot: WidgetSnapshot, budget: Int, showsName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsName, !snapshot.childFirstName.isEmpty {
                Text(snapshot.childFirstName)
                    .typeRole(.label)
                    .foregroundStyle(palette.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            if let mission = snapshot.missionFeatured {
                link(mission, tint: palette.mission, budget: budget)
            }

            if snapshot.missionFeatured != nil && snapshot.questionFeatured != nil {
                Rectangle().fill(palette.border).frame(height: 1)
            }

            if let question = snapshot.questionFeatured {
                link(question, tint: palette.question, budget: budget)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The last resort, and the same shape the small family uses: one prompt read properly, and
    /// the other named rather than quoted.
    private func lead(_ snapshot: WidgetSnapshot, budget: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let next = snapshot.nextUp {
                link(next, tint: next.label == "Question" ? palette.question : palette.mission,
                     budget: budget)
            }
            Spacer(minLength: 0)
            if let other = [snapshot.missionFeatured, snapshot.questionFeatured]
                .compactMap({ $0 })
                .first(where: { $0.label != snapshot.nextUp?.label }) {
                SlotLabel(
                    label: other.item.isDone ? "\(other.label) done" : "\(other.label) waiting",
                    symbol: other.item.symbolName,
                    tint: other.item.isDone ? palette.done : palette.inkMuted,
                    isDone: other.item.isDone
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A finished prompt still links: it opens the entry it produced, which is what a parent
    /// tapping a done row is looking for.
    private func link(
        _ featured: WidgetSnapshot.Featured,
        tint: Color,
        budget: Int
    ) -> some View {
        Link(destination: WidgetDeepLink.assignment(featured.item.assignmentId).url) {
            PromptRow(featured: featured, tint: tint, budget: budget)
        }
    }
}
