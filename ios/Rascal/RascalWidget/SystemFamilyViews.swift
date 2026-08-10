import SwiftUI
import WidgetKit

// MARK: - Small

/// One prompt, in full, and a quiet line for the other.
///
/// **The small family leads rather than lists.** There is room here for one prompt a parent can
/// actually read and one line telling them the other exists; two half-prompts is two things
/// nobody can read. The lead is the first unfinished one, mission before question, so the widget
/// answers "what now" rather than "what is outstanding" — the second is a backlog, and this
/// product does not show backlogs.
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
            VStack(alignment: .leading, spacing: 6) {
                SlotLabel(
                    label: next.label,
                    symbol: next.item.symbolName,
                    tint: tint(for: next.label)
                )

                WordSafePrompt(text: next.item.body, role: .metadata)
                    .foregroundStyle(palette.ink)

                Spacer(minLength: 0)

                if let other = other(than: next, in: snapshot) {
                    footer(other)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The lead prompt is what a tap on this family opens. `widgetURL` covers the whole
            // widget on the Home Screen, so this is the tap target rather than one of several.
            .widgetURL(WidgetDeepLink.assignment(next.item.assignmentId).url)
        }
    }

    /// The other prompt, named and stated — never counted.
    @ViewBuilder
    private func footer(_ other: WidgetSnapshot.Featured) -> some View {
        HStack(spacing: 4) {
            Image(systemName: other.item.isDone ? "checkmark" : other.item.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(other.item.isDone ? "\(other.label) done" : "\(other.label) waiting")
                .typeRole(.label)
        }
        .foregroundStyle(other.item.isDone ? palette.done : palette.inkMuted)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
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

/// Both prompts, each in its own right.
///
/// The medium family is the one that can afford to show the pair without either becoming a
/// footnote, so it does — two rows, each tapping through to its own composer.
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
            CompleteView(name: snapshot.childFirstName)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !snapshot.childFirstName.isEmpty {
                    Text(snapshot.childFirstName)
                        .typeRole(.label)
                        .foregroundStyle(palette.inkFaint)
                }

                if let mission = snapshot.missionFeatured {
                    link(mission, tint: palette.mission)
                }

                if snapshot.missionFeatured != nil && snapshot.questionFeatured != nil {
                    Rectangle()
                        .fill(palette.border)
                        .frame(height: 1)
                }

                if let question = snapshot.questionFeatured {
                    link(question, tint: palette.question)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Each row is its own tap target. A finished prompt still links: it opens the entry it
    /// produced, which is the thing a parent tapping a done row is looking for.
    private func link(_ featured: WidgetSnapshot.Featured, tint: Color) -> some View {
        Link(destination: WidgetDeepLink.assignment(featured.item.assignmentId).url) {
            PromptRow(featured: featured, tint: tint, lineLimit: 2)
        }
    }
}
