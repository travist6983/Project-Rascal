import Foundation
import StoreKit

/// The `Transaction.updates` listener, alive for the life of the process.
///
/// **Started at launch and never cancelled**, before any paywall can be shown. It is the delivery
/// path for renewals, refunds, Ask-to-Buy approvals, purchases made on another device, and any
/// transaction Apple could not hand over during a session. A purchase that completed while the app
/// was backgrounded arrives here; without this listener it is never finished and Apple redelivers
/// it forever.
///
/// **Process-wide by architectural necessity, not preference** — the same reason `PushCenter` and
/// `MediaCoordinator` are. `Transaction.updates` is a single global stream that must be drained by
/// exactly one reader, and it starts producing before `OnboardingGate` has resolved a session, let
/// alone before Settings exists. Do not create a second one.
///
/// It holds no tier and decides nothing. Per D5 a transaction is a receipt: the body is
/// `finish()`, then ask the **server**.
@MainActor
@Observable
final class SubscriptionCenter {
    static let shared = SubscriptionCenter()

    /// Bumped **only** when a verified transaction came off `Transaction.updates`.
    ///
    /// **This is how an open paywall notices an Ask-to-Buy approval.** The parent is looking at
    /// "This purchase needs approval" when somebody taps approve on another device; the
    /// transaction arrives on this stream, and a view watching this counter re-reads and moves on.
    ///
    /// **It is deliberately not bumped by `refresh()`, and that separation is a bug fix rather
    /// than tidiness.** `refresh()` is also the foreground re-check, so when one counter served
    /// both, *any* app foreground looked identical to an approval: a parent who started an
    /// Ask-to-Buy, backgrounded the app to go and ask, and came back was told **"Your subscription
    /// is being confirmed — there's nothing else you need to do"** while nobody had approved
    /// anything. That sentence was false, and it was terminal, so the screen never recovered.
    private(set) var transactionRevision = 0

    private var listener: Task<Void, Never>?
    private var api: APIClient?

    private init() {}

    /// Idempotent. `OnboardingGate` calls this from a `.task` that sits **above** `RootView`'s
    /// `.id(child.id)`, so switching child does not tear the listener down and a second call does
    /// not start a second drain.
    func start(api: APIClient) {
        self.api = api
        guard listener == nil else { return }
        listener = Task { [weak self] in
            await SubscriptionStore.drain(Transaction.updates) { [weak self] in
                await self?.refresh()
                await self?.transactionDelivered()
            }
        }
    }

    /// Ask the one route that knows. Also the foreground re-check.
    ///
    /// **The answer is deliberately discarded.** Per D5 there is one authority on the tier and one
    /// place it is read — each screen's own `SubscriptionModel`, from `GET /v1/families/me`. A
    /// copy cached here would be a second answer to the same question that nothing invalidates on
    /// sign-out, which is exactly the shape that ends with one screen saying `free` and another
    /// saying `subscribed`. This type's job is to *finish transactions* and to say "something
    /// changed"; it is not allowed to hold an opinion about what.
    ///
    /// The call itself is not wasted: it is the listener honouring "refresh the entitlement from
    /// the server" at the moment the transaction arrives, rather than leaving it to whenever a
    /// screen next appears.
    func refresh() async {
        guard let api else { return }
        _ = try? await api.family()
    }

    /// Only the drain calls this. See `transactionRevision`.
    private func transactionDelivered() {
        transactionRevision &+= 1
    }
}
