import Foundation

/// When a failed upload becomes eligible again.
///
/// Pure arithmetic, deliberately separated from the uploader so it can be tested without a
/// network, a session, or a clock. The schedule lives on the media row as `nextAttemptAt`, not
/// in memory, so it survives a relaunch — a backoff that resets on every launch is not a
/// backoff.
nonisolated enum UploadBackoff {
    /// First retry roughly here, doubling from there.
    static let base: TimeInterval = 5
    /// No point waiting longer than this; the sweep runs on foreground anyway.
    static let ceiling: TimeInterval = 10 * 60
    /// Past this many attempts the row is `failed` — surfaced and manually retryable, never
    /// silently dropped.
    static let maxAttempts = 6

    /// Exponential, capped, and **jittered**.
    ///
    /// The jitter is not a refinement. A handful of photos on one entry fail together the
    /// moment a connection drops, and without it they would all become eligible in the same
    /// instant, retry in lockstep, and fail together again — forever, in a tightening
    /// convoy. Spreading them means one succeeding tells you the network is back.
    ///
    /// A multiplier in `0.5...1.5` rather than full `0...delay` jitter: full jitter can retry
    /// almost immediately, which on a dropped connection just burns a request. This keeps the
    /// backoff's shape and still breaks the convoy.
    static func delay(forAttempt attempt: Int, jitter: Double = .random(in: 0.5...1.5)) -> TimeInterval {
        let exponential = base * pow(2, Double(max(0, attempt - 1)))
        return min(ceiling, exponential) * jitter
    }

    /// `nil` means the row has exhausted its attempts and should be marked `failed`.
    static func nextAttempt(
        after attempt: Int,
        now: Date = Date(),
        jitter: Double = .random(in: 0.5...1.5)
    ) -> Date? {
        guard attempt < maxAttempts else { return nil }
        return now.addingTimeInterval(delay(forAttempt: attempt, jitter: jitter))
    }

    /// Is this row due?  A row that has never been attempted is due immediately.
    static func isEligible(nextAttemptAt: Date?, now: Date = Date()) -> Bool {
        guard let nextAttemptAt else { return true }
        return nextAttemptAt <= now
    }
}

extension Media {
    /// Ordering key for the sweep.
    ///
    /// **By `nextAttemptAt`, not strictly oldest-first.** Oldest-first lets one permanently
    /// failing row sit at the head of the queue and starve everything behind it: it is always
    /// the oldest, so it is always tried first, and its backoff delays every photo after it.
    /// Sorting by when each row is *due* pushes a repeatedly-failing row to the back on its
    /// own, because each failure moves its `nextAttemptAt` further out.
    ///
    /// A row never attempted has no `nextAttemptAt` and sorts first, which is what you want:
    /// the photo just taken goes before the one that has failed five times.
    var sweepOrderKey: Date {
        nextAttemptAt ?? .distantPast
    }

    func recordAttemptFailure(now: Date = Date(), jitter: Double = .random(in: 0.5...1.5)) {
        attemptCount += 1
        if let next = UploadBackoff.nextAttempt(after: attemptCount, now: now, jitter: jitter) {
            nextAttemptAt = next
            state = .staged
        } else {
            nextAttemptAt = nil
            state = .failed
        }
    }

    /// A manual retry clears the backoff. Someone is standing there having pressed a button;
    /// making them wait out an exponential delay would be absurd.
    func resetForManualRetry() {
        attemptCount = 0
        nextAttemptAt = nil
        if state == .failed { state = .staged }
    }
}
