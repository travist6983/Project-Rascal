import SwiftUI

/// The one screen shown after a first sign-in, before the first Today.
///
/// **Named `TrialWelcomeScreen` because `WelcomeScreen` is taken** — that is the signed-*out*
/// sign-in screen, and two "welcome"s a tab apart would be a real mis-read.
///
/// What it deliberately is not, from the copy file's rules and the approved design: no illustration
/// of a child, no stock photography, no progress dots, no carousel. One screen, one primary action.
///
/// **No progress rail**, and the design says why: *"this is not one of the six setup steps, and a
/// rail of one is a control that lies."*
///
/// **No countdown, here or ever.** `trial_ends_at` is on the wire and this screen does not read it.
/// The two weeks are a fact stated once in a sentence, not a clock that starts running.
///
/// **Plain canvas, not `Gradients.wash`** — the design is explicit and it corrects the obvious
/// instinct: *"The wash is reserved to the welcome screen and this screen comes **after** sign-in,
/// so it is a step, and steps are plain canvas."* The wash is for emotional beats — onboarding,
/// all-caught-up, throwbacks, sealed letters — and this is a step in a flow.
struct TrialWelcomeScreen: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            ScrollView { copy }
                // Pinned rather than pushed down by a `Spacer`, so the action does not move as the
                // type grows — at accessibility sizes a spacer-positioned button leaves the screen.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    action
                        .padding(.horizontal, margin)
                        .padding(.top, 26)
                        .padding(.bottom, 12)
                        .background(PinnedActionBackdrop())
                }
        }
    }

    /// **Lifted out of the `ScrollView`, and not for tidiness.** `ImageRenderer` does not rasterize
    /// a scroll view's content — it draws the ground and stops — so a screenshot of the whole screen
    /// is a full-height cream rectangle that passes every check. `PaywallSheet` carries the same
    /// split for the same reason, and the phase-37b row records the harness that produced blank
    /// cream and reported success.
    var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            copy
            action.padding(.horizontal, margin)
        }
    }

    private var copy: some View {
        // Spacing 0 at this level so the inset below is exactly the inset, rather than the inset
        // plus a stack gap.
        VStack(alignment: .leading, spacing: 0) {
            // The design's 72 from the top, scaled — at accessibility sizes a fixed inset is a
            // large fraction of the screen given to nothing.
            //
            // **A child view rather than a `@ScaledMetric` on this struct**, and that is not
            // cosmetic: `content` is read as a *property* by the screenshot harness, on an instance
            // that was never installed in a hierarchy — so a metric stored here resolves to its
            // default and every accessibility render would have been taken at the wrong inset. A
            // metric inside a child is evaluated where the environment actually is.
            TopInset()

            VStack(alignment: .leading, spacing: 14) {
            Text(MembershipCopy.TrialWelcome.title)
                .typeRole(.display)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(MembershipCopy.TrialWelcome.body)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, margin)
    }

    private var action: some View {
        Button(MembershipCopy.TrialWelcome.action, action: onContinue)
            .buttonStyle(PrimaryButtonStyle())
    }

    /// 28 — the onboarding margin, wider than a board's 16. This screen is a step in that flow and
    /// takes its measurements.
    private let margin: CGFloat = 28
}

/// The clear space above the title. See `TrialWelcomeScreen.copy` for why it is a view.
private struct TopInset: View {
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 72

    var body: some View {
        Color.clear.frame(height: height)
    }
}

#if DEBUG
#Preview("Trial welcome") {
    TrialWelcomeScreen {}
}

#Preview("Trial welcome — XXL") {
    TrialWelcomeScreen {}
        .environment(\.dynamicTypeSize, .xxLarge)
}

#Preview("Trial welcome — AX5") {
    TrialWelcomeScreen {}
        .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
