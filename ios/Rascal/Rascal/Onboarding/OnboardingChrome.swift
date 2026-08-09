import SwiftUI

/// The furniture every onboarding step shares: the progress rail, the step scaffold, and the
/// two button treatments.
///
/// **Where the tokens come from.** `docs/design-system.md` says in its own second paragraph that
/// it wins over a mockup, and `ios/CLAUDE.md` names it the authority for writing SwiftUI. So
/// colour and type here are `Palette` and `TypeRole` even where the export drew something a few
/// points larger — the export is followed for layout, copy, sequencing and motion, which is what
/// it is actually the authority on. Every substitution is listed in
/// `docs/reports/phase-5-onboarding.md`.

enum OnboardingLayout {
    /// Onboarding breathes wider than the rest of the app. `Layout.screenMargin` is 16 and it is
    /// tuned for lists of cards; these are single-purpose screens with one sentence and one
    /// button on them, and 16 makes a 34pt headline look like it is falling off the edge. The
    /// export uses 30 in a 393pt frame, which is this.
    static let margin: CGFloat = 28

    /// Clear of the progress rail and the notch.
    static let topInset: CGFloat = 72

    /// The rail itself.
    static let railHeight: CGFloat = 4
    static let railTopInset: CGFloat = 8

    /// The export's fill transition. Slower than a tap and faster than a page turn — it should
    /// read as the screen settling, not as an animation playing.
    static let railFill = Animation.easeOut(duration: 0.52)
}

/// Four steps, one rail. Hidden on the welcome screen, which is not a step.
struct OnboardingProgressBar: View {
    let step: OnboardingStep

    private var fraction: CGFloat {
        CGFloat(step.ordinal) / CGFloat(OnboardingStep.count)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.border)
                Capsule()
                    .fill(Color.terracotta)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: OnboardingLayout.railHeight)
        .animation(OnboardingLayout.railFill, value: step)
        .padding(.horizontal, OnboardingLayout.margin)
        .padding(.top, OnboardingLayout.railTopInset)
        // One progress element, not four. VoiceOver reads the rail as a whole, and the step
        // headings carry the detail.
        .accessibilityElement()
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(step.ordinal) of \(OnboardingStep.count)")
    }
}

/// Heading, supporting line, content, and a footer pinned to the bottom third.
///
/// The bottom third is a design-system layout rule — "primary actions live in the bottom third,
/// one-thumb reachable" — and it is why every step puts its content in the middle and its button
/// underneath rather than stacking everything from the top.
struct OnboardingStepScaffold<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .typeRole(.screenTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let subtitle {
                Text(subtitle)
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            content()
                .padding(.top, 28)

            Spacer(minLength: 24)

            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OnboardingLayout.margin)
        .padding(.top, OnboardingLayout.topInset)
        .padding(.bottom, OnboardingLayout.margin)
    }
}

/// The same capsule as `PrimaryButtonStyle`, plus the one thing it has no opinion about: how a
/// primary action looks when it is not yet available.
///
/// The export fills a disabled Continue with `#D9CFC2`, which has no `Palette` equivalent and is
/// not being added as one. `chipPlain` under `inkFaint` is the nearest pair the palette already
/// owns and it reads the same way — present, waiting, not an error.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeRole(.cardTitle)
            .foregroundStyle(isEnabled ? Color.surface : Color.inkFaint)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(background(pressed: configuration.isPressed), in: Capsule())
            .contentShape(Capsule())
    }

    private func background(pressed: Bool) -> Color {
        guard isEnabled else { return .chipPlain }
        return pressed ? .terracottaDeep : .terracotta
    }
}

/// The quiet way out of a step — "Skip", "Change", "Not now". Underlined text, never a second
/// filled button competing with the real action.
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .typeRole(.body)
            .foregroundStyle(Color.inkMuted)
            .underline()
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }
}

/// Something went wrong and the parent can act on it. Stated under the control it belongs to,
/// in `inkMuted` rather than red — copy rules: nothing turns red, and this is not a scolding.
struct OnboardingNotice: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again", action: retry)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.terracotta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The back affordance. Present on every step but the first, because a parent who mistyped a
/// name two screens ago should not have to finish setup to fix it.
struct OnboardingBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.inkMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Back")
    }
}
