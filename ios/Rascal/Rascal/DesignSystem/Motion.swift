import SwiftUI

/// Motion from `docs/design-system.md`. Gentle and responsive, nothing theatrical.
///
/// Reduce Motion is honoured the way the spec asks: the completion check still *fills*, it just
/// doesn't spring. Removing the feedback entirely would be a different bug — the parent still
/// needs to know the tap landed.
enum Motion {
    /// Completion — the circular checkmark filling.
    static let completion = Animation.spring(response: 0.35, dampingFraction: 0.7)
    /// The same beat with Reduce Motion on: same duration, no overshoot.
    static let completionReduced = Animation.easeOut(duration: 0.35)

    /// Card tap: scale 0.98.
    static let tapScale: CGFloat = 0.98
    static let tap = Animation.easeOut(duration: 0.12)

    /// A completed card settling into Done Today.
    static let cardToDone = Animation.easeInOut(duration: 0.4)

    /// List insert — fade plus a slight rise.
    static let listInsert = AnyTransition.opacity.combined(with: .move(edge: .bottom))

    static func completion(reduceMotion: Bool) -> Animation {
        reduceMotion ? completionReduced : completion
    }
}

/// Card tap feedback: scale 0.98 over 0.12s, skipped under Reduce Motion.
struct TapScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.tapScale : 1)
            .animation(Motion.tap, value: configuration.isPressed)
    }
}

/// The circular terracotta checkmark. Fills with a spring and a light haptic.
///
/// This is the one moment of celebration in the app, and it is deliberately small: no confetti,
/// no stamp, no streak. A missed day is not a failure, so completing one is not a triumph — it
/// is an acknowledgement.
struct CompletionCheck: View {
    let isComplete: Bool
    var diameter: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(isComplete ? Color.terracotta : Color.clear)
                .overlay(
                    Circle().strokeBorder(
                        isComplete ? Color.terracotta : Color.border,
                        lineWidth: Layout.borderWidth * 1.5
                    )
                )
            Image(systemName: "checkmark")
                .font(.system(size: diameter * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(Color.surface)
                .scaleEffect(isComplete ? 1 : 0.4)
                .opacity(isComplete ? 1 : 0)
        }
        .frame(width: diameter, height: diameter)
        .animation(Motion.completion(reduceMotion: reduceMotion), value: isComplete)
        .accessibilityHidden(true)
    }
}

/// Light haptic on completion. Silent on devices without a taptic engine, which is correct —
/// it is reinforcement, never the only signal that something happened.
enum Haptics {
    @MainActor
    static func completion() {
        // `.success`, not a light impact. A light tap reads as "button pressed"; this is the
        // one moment in the app worth a warmer note, and it is still a single haptic rather
        // than a sequence.
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
