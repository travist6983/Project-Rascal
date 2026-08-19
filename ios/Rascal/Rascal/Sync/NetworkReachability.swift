import Foundation
import Network

/// Whether there is a network path at all.
///
/// It exists for one rule: **never show a control that cannot act.** "Retry now" with the radio off
/// is a button that reports failure it already knew about, and a parent pressing it learns that the
/// card is decorative — at the exact moment they are worried about whether their photos are safe.
///
/// This is deliberately the *only* question it answers. The app already classifies "the radio
/// refused" from a `URLError` after a request fails (`MediaAccess.swift:125`), and it already
/// declines expensive and constrained paths for backfill by configuration. Neither can answer
/// "should this button be tappable", because both require having tried first.
///
/// `NWPathMonitor` reports `.satisfied` for a captive portal and for a router with no uplink, so
/// this can be true while nothing actually reaches the server. That is the right trade for gating a
/// control: a false "online" costs one honest failure message, a false "offline" hides the only way
/// a parent has to act.
@MainActor
@Observable
final class NetworkReachability {

    private(set) var isOnline: Bool
    private let monitor: NWPathMonitor?

    /// The live monitor. Starts pessimistic — `NWPathMonitor` delivers its first update
    /// asynchronously, and assuming online before it answers would enable the retry button for a
    /// frame on a phone in a tunnel.
    init() {
        isOnline = false
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.isOnline = online }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// A fixed answer, for tests and previews. No monitor is started.
    init(fixed: Bool) {
        isOnline = fixed
        monitor = nil
    }

    deinit {
        monitor?.cancel()
    }
}
