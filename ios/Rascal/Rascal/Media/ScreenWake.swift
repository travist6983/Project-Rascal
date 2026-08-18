import Foundation

/// The seam over `UIApplication.shared.isIdleTimerDisabled`.
///
/// It exists for one assertion: the screen is held awake while a recording is running, and
/// released the moment one is not. A leaked `true` keeps a parent's screen lit until the app is
/// killed — a battery complaint nobody would ever trace back to a voice note — so the release has
/// to be provable in a test rather than checked by watching a phone in a dark room.
///
/// One method rather than `acquire`/`release`, deliberately. A pair invites counting, and a count
/// is a thing that can be wrong: the caller states what it wants to be true and this sets it.
@MainActor
protocol ScreenWakeLocking {
    func setScreenAwake(_ awake: Bool)
}

/// Picks the real lock where UIKit exists.
///
/// A factory rather than a default argument because `LiveScreenWake` is conditionally compiled,
/// and a default argument naming it would stop `AudioPipeline` compiling anywhere UIKit is
/// absent — the same reason `NotificationAuthorizerFactory` exists.
@MainActor
enum ScreenWakeFactory {
    static func live() -> any ScreenWakeLocking {
        #if canImport(UIKit)
        LiveScreenWake()
        #else
        UnavailableScreenWake()
        #endif
    }
}

/// Used only where UIKit is absent. Never reached on iOS.
///
/// There is no screen to hold awake, so doing nothing is the honest answer rather than a
/// half-implementation that pretends to have held one.
@MainActor
struct UnavailableScreenWake: ScreenWakeLocking {
    func setScreenAwake(_ awake: Bool) {}
}

#if canImport(UIKit)
import UIKit

@MainActor
struct LiveScreenWake: ScreenWakeLocking {
    /// Assigning the same value twice is free, which is what lets the caller treat this as a
    /// statement of intent rather than a transition it has to track.
    func setScreenAwake(_ awake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = awake
    }
}
#endif
