import Foundation
import OSLog
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
///
/// **Since phase 145 it also carries the receipt to the server, when the server has not heard.**
/// `SubscriptionModel` hands over the JWS the device holds after a purchase and on a restore, and
/// nowhere else — so a purchase whose submission failed, or a renewal that landed while Apple's
/// webhook was down, left a household running out its trial and reading *Free* while Apple was
/// charging, until a parent happened to tap Restore. `reconcile()` is the same hand-over, run at
/// the two moments this type learns something without anybody tapping: the listener starting, and
/// a transaction coming off it. It still decides nothing — it reads the server's answer to know
/// whether to bother the server, and it reads it again to know whether a screen should look.
@MainActor
@Observable
final class SubscriptionCenter {
    static let shared = SubscriptionCenter()

    private static let log = Logger(subsystem: "app.rascal", category: "subscription")

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
    ///
    /// **It is not bumped by `reconcile()` either, for the same reason one door over.** A
    /// reconciliation runs at launch; a launch that bumped this would look like an approval to a
    /// paywall left on "needs approval", which is the identical bug arriving by a different
    /// route. What a reconciliation has to say goes on `householdRevision` below.
    private(set) var transactionRevision = 0

    /// Bumped when `reconcile()` handed the server a receipt and the server answered that the
    /// household is now subscribed — **and by nothing else.**
    ///
    /// **A sibling of `transactionRevision` rather than a second writer to it, because the two mean
    /// different things and a screen does different things about them.** `transactionRevision`
    /// says *a transaction came off `Transaction.updates`*, and a paywall parked on "This purchase
    /// needs approval" answers it by re-entering the confirmation window. This says *the server's
    /// answer has moved*, and the right response is a plain re-read — `refreshHousehold()`, which
    /// settles whatever is open against what the server now says. The reconciliation cannot know
    /// which screens are up, so it does not try: it says the one true thing and lets each screen
    /// ask the one route that knows.
    ///
    /// Not bumped by `refresh()`, and not bumped by a reconciliation the server answered with
    /// `free`, refused, or never received — there is nothing for a screen to re-read that it does
    /// not already show. **No household is kept here**: the answer that bumped this is discarded
    /// for the reason `refresh()` gives, and a screen that wants it goes and asks.
    private(set) var householdRevision = 0

    private var listener: Task<Void, Never>?
    private var api: APIClient?
    /// The receipt's source, behind the same interface `SubscriptionModel` uses, for the same
    /// reason: `reconcile()` has to be provable without an App Store. Production is
    /// `SubscriptionStore()`, which is also the only place the JWS ever comes from.
    private let store: any SubscriptionPurchasing

    private init() {
        store = SubscriptionStore()
    }

    #if DEBUG
        /// A center holding an API client, a store, and **no listener**, for tests.
        ///
        /// `shared` is still the one production instance and the rule above is unchanged — a
        /// second *drain* of `Transaction.updates` is the thing that must not exist. This starts
        /// none: it exists so a test can assert the counter split, and drive `reconcile()` against
        /// a scripted server and a store with or without a receipt, without opening a
        /// process-lifetime stream on a global. Same seam, same reason, as
        /// `SubscriptionModel.init(previewing:)`.
        init(testing api: APIClient, store: any SubscriptionPurchasing) {
            self.api = api
            self.store = store
        }
    #endif

    /// Idempotent. `OnboardingGate` calls this from a `.task` that sits **above** `RootView`'s
    /// `.id(child.id)`, so switching child does not tear the listener down and a second call does
    /// not start a second drain.
    ///
    /// The first call also runs `reconcile()` once, alongside the drain rather than ahead of it:
    /// the drain must not wait on two network calls to start reading a stream that may already
    /// hold a transaction, and the reconciliation must not wait on a stream that may never produce
    /// one. It runs against whatever session the phone holds — see `reconcile()` for what happens
    /// when it holds none.
    func start(api: APIClient) {
        self.api = api
        guard listener == nil else { return }
        listener = Task { [weak self] in
            await SubscriptionStore.drain(Transaction.updates) { [weak self] in
                // The hand-over first, so that the re-read below — and every screen the bump
                // wakes — finds a server that has already been told what just arrived.
                await self?.reconcile()
                await self?.refresh()
                await self?.transactionDelivered()
            }
        }
        Task { [weak self] in await self?.reconcile() }
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

    /// Hand the server the receipt this device holds, if the server does not already know.
    ///
    /// **The defect this closes, found Sep 5, 2026.** The only two places that submitted the JWS
    /// were a purchase's confirmation and a restore — both behind a tap. If the purchase-time
    /// submission failed and Apple's webhook was lost, or a renewal arrived while the webhook was
    /// down, nothing on the device ever told the server about a receipt it was holding, and the
    /// household ran out its fortnight and read *Free* while Apple was charging.
    ///
    /// Four steps, and each one stops short of an opinion. Read the household; **a member is left
    /// alone** — the server already says what a receipt could prove, and a household on a grant is
    /// not offered a receipt it did not buy. Ask the store; nothing to hand over means nothing is
    /// sent. Submit; the server verifies, binds by the `appAccountToken` inside Apple's signature,
    /// and may only ever promote (D5, as amended by phases 140 and 143). If it now calls the
    /// household subscribed, `householdRevision` tells any open screen to go and read it.
    ///
    /// **Every failure is silent, including a `409` saying the receipt is another household's.**
    /// Nobody asked for this; there is no sentence a parent is waiting on and no state to leave
    /// behind. The `409` in particular is *already* said, in the one place a parent can act on it:
    /// `SubscriptionModel.settleReceiptElsewhere()`, when they tap Buy or Restore. A launch that
    /// wrote the same sentence under a card nobody was looking at would be a notice about nothing
    /// the parent did, which is the kind of copy `free-tier-copy.md` exists to forbid — and this
    /// type is not allowed to author copy in any case.
    ///
    /// **Nothing is asked before there is a session.** `start(api:)` runs before `OnboardingGate`
    /// has resolved one, deliberately, so on a fresh install this runs against a client holding no
    /// tokens. Rather than send a `GET` that can only `401`, it checks and leaves; a parent who
    /// signs in afterwards is reconciled by the next launch or the next transaction, and by the
    /// submission Buy and Restore already make.
    func reconcile() async {
        guard let api, await api.hasSession() else { return }
        guard let family = try? await api.family(), !family.isMember else { return }
        guard let signed = await store.currentEntitlement() else { return }
        let answer: FamilySummary
        do {
            answer = try await api.submitTransaction(signed)
        } catch {
            // Debug-level and never a sentence anywhere a parent looks. The receipt itself is not
            // logged: it is Apple's signed statement about a payment, not a diagnostic.
            Self.log.debug("receipt reconciliation not applied: \(String(describing: error), privacy: .private)")
            return
        }
        if answer.isSubscribed { householdRevision &+= 1 }
    }

    /// Only the drain calls this. See `transactionRevision`.
    private func transactionDelivered() {
        transactionRevision &+= 1
    }
}
