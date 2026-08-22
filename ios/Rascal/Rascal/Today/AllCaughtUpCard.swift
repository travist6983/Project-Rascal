import SwiftUI

/// The end of the board — either everything is done, or nothing has arrived yet.
///
/// Two states that look similar and mean opposite things, which is why they are one component with
/// one switch rather than two cards that drift apart. Neither congratulates anyone. There is no
/// count of consecutive days here and there never will be: a missed day is not a failure, so a
/// finished one is not a triumph.
///
/// The gradient is the app's emotional-beat wash, reserved for exactly this kind of moment —
/// onboarding, all-caught-up, throwbacks, sealed entries — and never a background for ordinary
/// content.
struct AllCaughtUpCard: View {
    enum Mode: Equatable {
        /// Work was finished today. Carries how much, spelled out.
        case caughtUp(doneToday: Int)
        /// The board is empty because nothing has been assigned yet — a new account, or the small
        /// hours before the day's prompts land.
        case nothingYet

        /// Which card the end of the board earns, if any.
        ///
        /// A pure rule rather than a computed property on the view, so the one decision that can
        /// congratulate a parent for nothing is testable without rendering anything.
        ///
        /// **"All caught up" requires having caught up with something.** An account whose scheduler
        /// has not run yet has an empty board and has done nothing, and telling someone on their
        /// first morning that they are all caught up is praise for no work. Anything still open —
        /// today or waiting — means the board is not finished and gets no card at all.
        ///
        /// **`locked` suppresses `.nothingYet` and only that.** The two cases are not alike:
        ///
        /// - *"Nothing waiting. Today's prompts arrive in the morning"* under four locked cards is a
        ///   flat contradiction on one screen. The prompts **have** arrived; this household is not
        ///   being served them. That sentence would be the app telling a parent something they can
        ///   see is false, which is worse than saying nothing.
        /// - *"All caught up"* over a locked board is **true and stays**. A free parent who answered
        ///   today's question has finished everything they were offered, and withholding the
        ///   acknowledgement because they did not pay would be the meanest reading available.
        ///
        /// A locked board with nothing done therefore gets no end-of-board card at all, which is
        /// what the locked cards themselves are already saying.
        static func forBoard(today: Int, waiting: Int, doneToday: Int, locked: Int = 0) -> Mode? {
            guard today == 0, waiting == 0 else { return nil }
            if doneToday == 0 { return locked == 0 ? .nothingYet : nil }
            return .caughtUp(doneToday: doneToday)
        }
    }

    let mode: Mode

    var body: some View {
        VStack(spacing: 0) {
            if case .caughtUp = mode {
                CompletionCheck(isComplete: true, diameter: 56, tint: .terracotta, check: .surface)
                    .padding(.bottom, 16)
            }

            Text(title)
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 22)
        .cardSurface(wash: Gradients.wash, border: .sealedBorder)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private var title: String {
        switch mode {
        case .caughtUp: "All caught up"
        case .nothingYet: "Nothing waiting"
        }
    }

    /// The design's own line, kept verbatim: it is the clearest statement of the app's posture
    /// anywhere in the product, and it took a design pass to arrive at.
    private var subtitle: String {
        switch mode {
        case .caughtUp(let count) where count > 0:
            "\(CountText.spelled(count)) \(count == 1 ? "thing" : "things") saved today. "
                + "Come back tomorrow — or don't. It'll wait."
        case .caughtUp:
            "Come back tomorrow — or don't. It'll wait."
        case .nothingYet:
            "Today's prompts arrive in the morning."
        }
    }
}

#if DEBUG
#Preview("All caught up") {
    ScrollView {
        VStack(spacing: 20) {
            SectionLabel("Caught up — three done")
            AllCaughtUpCard(mode: .caughtUp(doneToday: 3))

            SectionLabel("Caught up — one done")
            AllCaughtUpCard(mode: .caughtUp(doneToday: 1))

            SectionLabel("First run — nothing assigned yet")
            AllCaughtUpCard(mode: .nothingYet)
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
}

#Preview("All caught up — AX XXL") {
    ScrollView {
        VStack(spacing: 20) {
            AllCaughtUpCard(mode: .caughtUp(doneToday: 3))
            AllCaughtUpCard(mode: .nothingYet)
        }
        .padding(Layout.screenMargin)
    }
    .background(Color.canvas)
    .environment(\.dynamicTypeSize, .accessibility4)
}
#endif
