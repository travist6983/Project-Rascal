import Foundation

/// The gap between "Apple took the money" and "the server knows", which is the part everybody
/// gets wrong.
///
/// When `Product.purchase()` returns success, **the server has not been told.** Apple's
/// notification to `POST /v1/webhooks/app-store` is asynchronous: usually seconds, occasionally
/// minutes, very occasionally not until a retry. So the app must not flip to a subscribed state on
/// the strength of the local transaction — per D5 the device does not get to decide that — and it
/// equally must not leave a parent who has just been charged looking at a paywall.
///
/// What closes the gap is a bounded poll of the one authority, and then a sentence.
nonisolated enum EntitlementConfirmation {

    /// 1s, 2s, 4s, then 8s to a ceiling — **63 seconds across ten reads**, in one named constant
    /// rather than scattered through the caller.
    ///
    /// Front-loaded because the common case is fast: the webhook usually lands inside the first
    /// two or three reads, and a flat 8s would make the ordinary purchase feel broken for the
    /// eight seconds it takes to notice it already worked.
    static let schedule: [Duration] =
        [.seconds(1), .seconds(2), .seconds(4)] + Array(repeating: .seconds(8), count: 7)

    /// The restore window: 1s, 2s, 4s, 8s — fifteen seconds across four reads.
    ///
    /// Shorter than `schedule` on purpose. A purchase has just charged somebody and has earned a
    /// minute of patience; a restore is a parent tapping a row in Settings, and a row that spins
    /// for a minute reads as broken.
    static let restoreSchedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    enum Outcome: Equatable {

        /// The server says `subscribed`, and **carries the household that said so**.
        ///
        /// It returns the value rather than a bare case because the caller would otherwise read
        /// again to get it — and that second read can fail, which would leave the app subscribed
        /// with no household on screen. The read that proved it is the one to keep.
        case subscribed(FamilySummary)
        /// The window closed with the server still reporting `free`.
        ///
        /// **Not an error, and it must never be rendered as one.** The purchase succeeded; the
        /// confirmation is late. Nothing is required of the parent and nothing should be retried.
        case late
    }

    /// Read the household until it reports `subscribed`, or until the schedule runs out.
    ///
    /// `sleep` and `read` are injected so the whole behaviour is testable without waiting 63
    /// seconds and without a network — the real schedule is still the default, so a test exercises
    /// the shipped constant rather than a parallel one.
    ///
    /// **A failed read is not a failed confirmation.** A dropped connection in the middle of this
    /// window says nothing about whether Apple told the server, so a throwing read costs one
    /// attempt and the loop carries on.
    ///
    /// ~~Only the schedule ends it.~~ — **struck: that was never true, and it is the sentence that
    /// hid the defect.** The schedule bounds the **sleeps**; nothing here bounds a **read**. A
    /// `read` that answers slowly stretches this window by however long it takes, and one that
    /// never answers suspends it forever — so the honest worst case is the schedule *plus* ten
    /// reads, not the 63 seconds stated above. This is left as a property of `poll` rather than
    /// fixed here, because the caller is where the remedy belongs: `SubscriptionModel.confirm()`
    /// runs a deadline that moves the **screen** off `.confirming`, which is the thing a parent is
    /// actually stuck on, and leaves the read to finish or not. Bounding the read inside this loop
    /// instead would mean cancelling work that may be about to succeed.
    static func poll(
        schedule: [Duration] = Self.schedule,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        read: @Sendable () async throws -> FamilySummary
    ) async -> Outcome {
        for delay in schedule {
            do {
                try await sleep(delay)
            } catch {
                // Cancelled — the screen went away. The purchase is unaffected; there is simply
                // nobody left to tell.
                return .late
            }
            if let family = try? await read(), family.isSubscribed {
                return .subscribed(family)
            }
        }
        return .late
    }
}
