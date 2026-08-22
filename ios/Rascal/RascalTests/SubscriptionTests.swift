import Foundation
import Testing

@testable import Rascal

// MARK: - Doubles

/// A counter the drain callback and the household reader can bump from any isolation.
private actor Counter {
    private(set) var value = 0
    func bump() -> Int {
        value += 1
        return value
    }
    func read() -> Int { value }
}

/// Records what it was asked to do, and answers however the test needs.
///
/// **This double is what makes the most important assertion in the phase deterministic.** Whether
/// `appAccountToken` carries the family id decides whether a real customer's payment can ever be
/// attributed, and `docs/blocked.md` §10 means there is no App Store Connect product to prove it
/// against. A fake here proves the family id reaches the boundary; `SubscriptionStoreKitTests`
/// covers the one hop beyond it, and the PR says plainly which is which.
private actor FakeStore: SubscriptionPurchasing {
    private let offer: SubscriptionOffer?
    private var outcomes: [Result<PurchaseOutcome, SubscriptionStoreError>]
    private let restoreResult: Result<Void, SubscriptionStoreError>

    private(set) var purchases: [(plan: SubscriptionPlan, familyID: UUID)] = []
    private(set) var restores = 0

    /// When set, `purchase` parks here until `release()` — which is the only way to observe the
    /// model *during* a purchase rather than after one.
    private var holdPurchase = false
    private var held: CheckedContinuation<Void, Never>?

    init(
        offer: SubscriptionOffer? = .double,
        outcomes: [Result<PurchaseOutcome, SubscriptionStoreError>] = [.success(.purchased)],
        restoreResult: Result<Void, SubscriptionStoreError> = .success(()),
        holdPurchase: Bool = false
    ) {
        self.offer = offer
        self.outcomes = outcomes
        self.restoreResult = restoreResult
        self.holdPurchase = holdPurchase
    }

    /// Let a held purchase finish.
    func release() {
        holdPurchase = false
        held?.resume()
        held = nil
    }

    /// Loads that should fail before the offer starts resolving, so a retry has something to
    /// recover *from*.
    private var failLoads = 0
    func failNextLoads(_ count: Int) { failLoads = count }

    func loadOffer() async throws -> SubscriptionOffer {
        if failLoads > 0 {
            failLoads -= 1
            throw SubscriptionStoreError.productsUnavailable
        }
        guard let offer else { throw SubscriptionStoreError.productsUnavailable }
        return offer
    }

    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        purchases.append((plan, familyID))
        if holdPurchase {
            await withCheckedContinuation { held = $0 }
        }
        let next = outcomes.isEmpty ? Result.success(PurchaseOutcome.purchased) : outcomes.removeFirst()
        return try next.get()
    }

    func restore() async throws {
        restores += 1
        try restoreResult.get()
    }
}

extension SubscriptionOffer {
    /// D1's shape, with D1's prices. **Authored here and only here** — a test is allowed to know
    /// what $59.99 and $5.99 are, because it is asserting the arithmetic that turns them into
    /// "Two months free". No shipping code does.
    static let double = SubscriptionOffer(
        annual: OfferedPlan(
            id: SubscriptionProducts.annual,
            plan: .annual,
            displayName: "Yearly",
            displayPrice: "$59.99",
            price: Decimal(string: "59.99")!,
            priceFormat: .currency(code: "USD"),
            period: SubscriptionPeriodValue(value: 1, unit: .year),
            trial: SubscriptionPeriodValue(value: 2, unit: .week)
        ),
        monthly: OfferedPlan(
            id: SubscriptionProducts.monthly,
            plan: .monthly,
            displayName: "Monthly",
            displayPrice: "$5.99",
            price: Decimal(string: "5.99")!,
            priceFormat: .currency(code: "USD"),
            period: SubscriptionPeriodValue(value: 1, unit: .month),
            trial: SubscriptionPeriodValue(value: 2, unit: .week)
        )
    )

    /// The same offer with no introductory offer on either plan — a storefront where Apple did
    /// not grant the trial.
    static let withoutTrial = SubscriptionOffer(
        annual: OfferedPlan(
            id: SubscriptionProducts.annual, plan: .annual, displayName: "Yearly",
            displayPrice: "$59.99", price: Decimal(string: "59.99")!,
            priceFormat: .currency(code: "USD"),
            period: SubscriptionPeriodValue(value: 1, unit: .year), trial: nil
        ),
        monthly: OfferedPlan(
            id: SubscriptionProducts.monthly, plan: .monthly, displayName: "Monthly",
            displayPrice: "$5.99", price: Decimal(string: "5.99")!,
            priceFormat: .currency(code: "USD"),
            period: SubscriptionPeriodValue(value: 1, unit: .month), trial: nil
        )
    )
}

@MainActor
private func household(_ tier: String, id: UUID = UUID()) -> FamilySummary {
    FamilySummary(
        familyId: id,
        tier: tier,
        guardians: [
            GuardianSummary(
                userId: UUID(), displayName: "Travis", role: "parent",
                grantedAt: .now, isYou: true
            )
        ],
        pendingInvites: []
    )
}

/// A model wired to doubles, with the confirmation window collapsed to nothing so a test is not
/// waiting 63 seconds for a schedule whose *shape* is asserted separately.
@MainActor
private func makeModel(
    store: any SubscriptionPurchasing,
    read: @escaping @Sendable () async throws -> FamilySummary
) -> SubscriptionModel {
    SubscriptionModel(
        readHousehold: read,
        store: store,
        confirmationSchedule: Array(repeating: .zero, count: 10),
        confirmationSleep: { _ in }
    )
}

// MARK: - The purchase

@Suite("The purchase, and the household it is attributed to")
struct SubscriptionPurchaseTests {

    @Test("appAccountToken is the family id — the one assertion that cannot be got wrong")
    @MainActor
    func theTokenIsTheFamilyID() async {
        // A transaction made without it is unattributable permanently: not a bug to fix in the
        // next release, a support conversation per affected customer, forever.
        let familyID = UUID()
        let store = FakeStore()
        // `free`, because a household the server already calls subscribed is no longer offered a
        // purchase — see `anAlreadySubscribedHouseholdCannotBuy`.
        let model = makeModel(store: store) { await household("free", id: familyID) }

        await model.load()
        await model.buy()

        let purchases = await store.purchases
        #expect(purchases.count == 1)
        #expect(purchases.first?.familyID == familyID)
        // And it is the *household's* id, not some other UUID that happens to be to hand.
        #expect(purchases.first?.familyID == model.household?.familyId)
    }

    @Test("the annual plan is what a default purchase buys, per D1")
    @MainActor
    func annualIsPreselected() async {
        let store = FakeStore()
        let model = makeModel(store: store) { await household("free") }
        await model.load()
        #expect(model.plan == .annual)

        await model.buy()
        #expect(await store.purchases.first?.plan == .annual)
    }

    @Test("choosing monthly buys monthly — it is not hidden and not shamed")
    @MainActor
    func monthlyIsBuyable() async {
        let store = FakeStore()
        let model = makeModel(store: store) { await household("free") }
        await model.load()
        model.plan = .monthly

        await model.buy()
        #expect(await store.purchases.first?.plan == .monthly)
    }

    @Test("a second tap while the purchase is still in flight buys nothing twice")
    @MainActor
    func aSecondTapMidPurchaseBuysNothing() async {
        // Every other test here awaits `buy()` to completion, so the model is never observed
        // mid-purchase and `purchase = .purchasing` — the one line that closes the button while
        // the App Store sheet is up — was asserted by nothing.
        let store = FakeStore(holdPurchase: true)
        let model = makeModel(store: store) { await household("free") }
        await model.load()
        #expect(model.canBuy)

        let first = Task { await model.buy() }

        // Wait until the purchase has actually reached the store.
        var reached = false
        for _ in 0..<200 {
            if await store.purchases.count == 1 { reached = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(reached)

        // The button is closed, and a second tap is inert rather than a second charge.
        #expect(model.canBuy == false)
        #expect(model.purchase == .purchasing)
        await model.buy()
        #expect(await store.purchases.count == 1, "a double tap sent a second purchase")

        await store.release()
        await first.value
    }

    @Test("a household the server already calls subscribed is not offered a purchase")
    @MainActor
    func anAlreadySubscribedHouseholdCannotBuy() async {
        let store = FakeStore()
        let model = makeModel(store: store) { await household("subscribed") }
        await model.load()

        #expect(model.canBuy == false)
        await model.buy()
        #expect(await store.purchases.isEmpty, "a subscribed household was sent through checkout")
    }

    @Test("coming back to the app does not turn a pending approval into a confirmation")
    @MainActor
    func aForegroundDoesNotConsumeAskToBuy() async {
        // The bug this pins: `SubscriptionCenter.refresh()` is the foreground re-check, and when
        // it shared one counter with the transaction drain, every foreground reached
        // `transactionArrived()` and — from `.awaitingApproval` — ran the confirmation window to
        // its terminal "Your subscription is being confirmed. There's nothing else you need to
        // do." Nobody had approved anything, and the screen never recovered.
        let store = FakeStore(outcomes: [.success(.pending)])
        let model = makeModel(store: store) { await household("free") }
        await model.load()
        await model.buy()
        #expect(model.purchase == .awaitingApproval)

        // This is what a foreground does now.
        await model.refreshHousehold()

        #expect(model.purchase == .awaitingApproval, "a foreground consumed the pending approval")
    }

    @Test("an approval the server has honoured does close the pending state")
    @MainActor
    func anApprovedAskToBuyClosesOnRefresh() async {
        let store = FakeStore(outcomes: [.success(.pending)])
        let subscribed = Counter()
        let model = makeModel(store: store) {
            await household(await subscribed.read() > 0 ? "subscribed" : "free")
        }
        await model.load()
        await model.buy()
        #expect(model.purchase == .awaitingApproval)

        _ = await subscribed.bump()
        await model.refreshHousehold()

        #expect(model.purchase == .subscribed)
    }

    @Test("a cancelled purchase is silent — no error, no toast, no are-you-sure")
    @MainActor
    func cancellationIsSilent() async {
        let store = FakeStore(outcomes: [.success(.cancelled)])
        let model = makeModel(store: store) { await household("free") }
        await model.load()

        await model.buy()

        #expect(model.purchase == .idle)
        if case .failed = model.purchase { Issue.record("a cancellation rendered as an error") }
        #expect(model.notice == nil)
        // And they can change their mind back.
        #expect(model.canBuy)
    }

    @Test("Ask to Buy is a state, not a failure")
    @MainActor
    func pendingIsNotAFailure() async {
        let store = FakeStore(outcomes: [.success(.pending)])
        let model = makeModel(store: store) { await household("free") }
        await model.load()

        await model.buy()

        #expect(model.purchase == .awaitingApproval)
        if case .failed = model.purchase { Issue.record("Ask to Buy rendered as an error") }
        // **Not buyable again.** A second purchase while one is awaiting approval is a second
        // charge for one intent.
        #expect(model.canBuy == false)
    }

    @Test("an approval arriving on Transaction.updates re-enters the confirmation window")
    @MainActor
    func approvalConfirmsRatherThanAssuming() async {
        // The approval means Apple now knows. It does **not** mean the server does — that is the
        // same gap a fresh purchase has, arriving by a different door.
        let store = FakeStore(outcomes: [.success(.pending)])
        let reads = Counter()
        let model = makeModel(store: store) {
            let n = await reads.bump()
            return await household(n >= 3 ? "subscribed" : "free")
        }
        await model.load()
        await model.buy()
        #expect(model.purchase == .awaitingApproval)

        await model.transactionArrived()

        #expect(model.purchase == .subscribed)
        // And it did not buy anything a second time.
        #expect(await store.purchases.count == 1)
    }

    @Test("an unverified transaction does not advance, and is reported rather than swallowed")
    @MainActor
    func unverifiedDoesNotAdvance() async {
        let store = FakeStore(outcomes: [.failure(.unverified)])
        let model = makeModel(store: store) { await household("free") }
        await model.load()

        await model.buy()

        guard case .failed(let message) = model.purchase else {
            Issue.record("an unverified transaction must not advance the purchase")
            return
        }
        #expect(message == SubscriptionStoreError.unverified.userMessage)
        #expect(model.household?.isSubscribed == false)
    }

    @Test("a store refusal is a sentence, and the parent may try again")
    @MainActor
    func aRefusalIsRecoverable() async {
        let store = FakeStore(outcomes: [.failure(.storeKit("The App Store couldn't be reached."))])
        let model = makeModel(store: store) { await household("free") }
        await model.load()

        await model.buy()

        #expect(model.purchase == .failed("The App Store couldn't be reached."))
        // A refusal is the one terminal state a parent can retry from — nothing was charged.
        #expect(model.canBuy)
    }
}

// MARK: - The confirmation gap

@Suite("The gap between Apple taking the money and the server knowing")
struct EntitlementConfirmationTests {

    @Test("free three times then subscribed reaches subscribed, and does not error")
    @MainActor
    func theGapClosesWhenTheServerCatchesUp() async {
        let store = FakeStore()
        let reads = Counter()
        let model = makeModel(store: store) {
            let n = await reads.bump()
            // One read for `load`, then the webhook has not landed for three, then it has.
            return await household(n > 4 ? "subscribed" : "free")
        }
        await model.load()

        await model.buy()

        #expect(model.purchase == .subscribed)
        #expect(model.household?.isSubscribed == true)
        if case .failed = model.purchase { Issue.record("a late confirmation rendered as a failure") }
    }

    @Test("a confirmation that never lands ends reassuring, not failed — and buys nothing again")
    @MainActor
    func aTimeoutIsNotAnError() async {
        let store = FakeStore()
        let model = makeModel(store: store) { await household("free") }
        await model.load()

        await model.buy()

        // Terminal, and terminal in the reassuring direction. `.failed` here would tell a parent
        // who has just been charged that something went wrong.
        #expect(model.purchase == .late)
        if case .failed = model.purchase { Issue.record("a late confirmation rendered as a failure") }
        // **The whole point.** A timeout must not become another purchase.
        #expect(model.canBuy == false)
        await model.buy()
        #expect(await store.purchases.count == 1, "a late confirmation caused a second charge")
    }

    @Test("a late confirmation that lands on the next foreground closes itself")
    @MainActor
    func aLateConfirmationClosesOnRefresh() async {
        let store = FakeStore()
        let subscribed = Counter()
        let model = makeModel(store: store) {
            let n = await subscribed.read()
            return await household(n > 0 ? "subscribed" : "free")
        }
        await model.load()
        await model.buy()
        #expect(model.purchase == .late)

        _ = await subscribed.bump()
        await model.refreshHousehold()

        #expect(model.purchase == .subscribed)
    }

    @Test("the window is bounded and front-loaded rather than a spinner")
    func theScheduleIsBounded() {
        let schedule = EntitlementConfirmation.schedule
        #expect(schedule.count == 10)
        #expect(schedule.first == .seconds(1))
        let total = schedule.reduce(Duration.zero, +)
        #expect(total == .seconds(63))
        #expect(total <= .seconds(70))
    }

    @Test("a read that throws costs one attempt rather than ending the window")
    func aThrowingReadDoesNotEndIt() async {
        let reads = Counter()
        let outcome = await EntitlementConfirmation.poll(
            schedule: Array(repeating: .zero, count: 4),
            sleep: { _ in },
            read: {
                if await reads.bump() < 3 { throw CancellationError() }
                return await household("subscribed")
            }
        )
        guard case .subscribed(let family) = outcome else {
            Issue.record("the window should have closed subscribed, got \(outcome)")
            return
        }
        // And it hands back the household it proved, so the caller never re-reads.
        #expect(family.isSubscribed)
    }

    @Test("a cancelled sleep ends the window as late, never as subscribed")
    func aCancelledSleepIsLateNotSubscribed() async {
        // `poll` returns `.late` when the sleep throws — the screen went away. Every other test
        // passes a non-throwing sleep, so this branch was unexercised, and a mutation of it into
        // `.subscribed` would have told a parent they were subscribed on the strength of a
        // cancellation.
        let reads = Counter()
        let outcome = await EntitlementConfirmation.poll(
            schedule: Array(repeating: .zero, count: 4),
            sleep: { _ in throw CancellationError() },
            read: {
                _ = await reads.bump()
                return await household("subscribed")
            }
        )
        #expect(outcome == .late)
        // And it gave up before asking, because there was nobody left to tell.
        #expect(await reads.read() == 0)
    }

    @Test("nothing but the server can produce a subscribed state")
    @MainActor
    func onlyTheServerSaysSubscribed() async {
        // The store says the purchase succeeded and the server keeps saying `free`. The screen
        // must not claim otherwise — D5, and the same rule as "the device never decides what day
        // it is".
        let model = makeModel(store: FakeStore()) { await household("free") }
        await model.load()
        await model.buy()

        #expect(model.household?.isSubscribed == false)
        #expect(model.purchase != .subscribed)
    }
}

// MARK: - What the paywall can offer

@Suite("What the paywall may offer, and when it may not")
struct PaywallOfferTests {

    @Test("with no household there is no buy button, because there would be no appAccountToken")
    @MainActor
    func noHouseholdMeansNoButton() async {
        let store = FakeStore()
        let model = makeModel(store: store) { throw CancellationError() }
        await model.load()

        #expect(model.canBuy == false)
        guard case .unavailable = model.phase else {
            Issue.record("a household that could not be read must not offer a purchase")
            return
        }
        #expect(model.offer == nil)
    }

    @Test("buy() is inert when there is nothing to attribute it to")
    @MainActor
    func buyIsInertWithoutAHousehold() async {
        let store = FakeStore()
        let model = makeModel(store: store) { throw CancellationError() }
        await model.load()

        await model.buy()

        // Not `.failed` — nothing was attempted, so there is nothing to report.
        #expect(model.purchase == .idle)
        #expect(await store.purchases.isEmpty, "a purchase was made with no household")
    }

    @Test("two screens loading the same model at once do not race each other")
    @MainActor
    func loadIsNotReentrant() async {
        // Not a hypothetical: `SubscriptionSection` and `PaywallSheet` both call `load()` from a
        // `.task`, and the section is what presents the sheet — so with the paywall up, both are
        // alive and both load.
        let reads = Counter()
        let model = makeModel(store: FakeStore()) {
            _ = await reads.bump()
            return await household("free")
        }

        async let first: Void = model.load()
        async let second: Void = model.load()
        _ = await (first, second)

        let count = await reads.read()
        #expect(count == 1, "the household was read \(count) times for one load")
        guard case .ready = model.phase else {
            Issue.record("a re-entrant load left the paywall in \(model.phase)")
            return
        }
    }

    @Test("one approval reaching the model twice runs one confirmation, not two")
    @MainActor
    func confirmIsNotReentrant() async {
        // Both screens watch `SubscriptionCenter.revision`, so a single Ask-to-Buy approval calls
        // `transactionArrived()` twice on one model. Two polling loops would race to a terminal
        // state, and the winner would decide what the parent was told.
        let store = FakeStore(outcomes: [.success(.pending)])
        let reads = Counter()
        let model = makeModel(store: store) {
            _ = await reads.bump()
            return await household("free")
        }
        await model.load()
        await model.buy()
        #expect(model.purchase == .awaitingApproval)

        let before = await reads.read()
        async let first: Void = model.transactionArrived()
        async let second: Void = model.transactionArrived()
        _ = await (first, second)

        // **One confirmation window, not two.** Ten reads for the single window the guard let
        // through, plus one: by the time the second call arrives `purchase` is `.confirming`
        // rather than `.awaitingApproval`, so it takes the `refreshHousehold` branch and reads
        // once. Two windows would be twenty, and the two loops would race to a terminal state.
        let window = await reads.read() - before
        #expect(window == 11, "one approval produced \(window) reads")
        #expect(model.purchase == .late)
    }

    @Test("an empty product load renders a retry, never a blank paywall")
    @MainActor
    func emptyProductsRenderARetry() async {
        // An empty `Product.products(for:)` result is the single most common StoreKit failure and
        // looks exactly like a network problem.
        let store = FakeStore(offer: nil)
        let model = makeModel(store: store) { await household("free") }
        await model.load()

        // **Phase 108 changed this assertion's shape, not its meaning.** `Phase.unavailable` carried
        // a `String` and the check was on that string; it now carries a cause, because phase 108
        // makes an empty product load the *ordinary* state and the two reasons had to stop rendering
        // the same sentence. The thing being asserted is the same and is now structural rather than
        // textual: this is the products' failure and not the household's.
        guard case .unavailable(.products) = model.phase else {
            Issue.record("an empty product load must not render as a paywall")
            return
        }
        #expect(model.canBuy == false)
        // The household did load, so this is the products' failure and not the household's — the
        // two say different things because a parent can act on one of them.
        #expect(model.household != nil)
    }

    @Test("a retry after a failed load succeeds once the store answers")
    @MainActor
    func retryRecovers() async {
        // This used to load once against a store that had never failed, assert `.ready`, and call
        // that a retry. It proved nothing about recovery.
        let store = FakeStore()
        await store.failNextLoads(1)
        let model = makeModel(store: store) { await household("free") }

        await model.load()
        guard case .unavailable = model.phase else {
            Issue.record("a failed product load should leave the paywall unavailable")
            return
        }
        #expect(model.canBuy == false)

        // The Try again button does exactly this.
        await model.load()

        guard case .ready = model.phase else {
            Issue.record("the retry did not recover; phase is \(model.phase)")
            return
        }
        #expect(model.canBuy)
    }

    @Test("with no trial on the product, nothing on screen promises one")
    @MainActor
    func noTrialMeansNoTrialCopy() async {
        let store = FakeStore(offer: .withoutTrial)
        let model = makeModel(store: store) { await household("free") }
        await model.load()

        #expect(model.selectedPlan != nil)
        #expect(model.selectedPlan?.trial == nil)
        #expect(PlanCopy.buyLabel(model.selectedPlan) == "Subscribe")
        #expect(PlanCopy.priceLine(SubscriptionOffer.withoutTrial.annual) == "$59.99 a year")
    }

    @Test("with a trial, the label and the price line both come from the product")
    func aTrialIsReadOffTheProduct() {
        #expect(PlanCopy.buyLabel(SubscriptionOffer.double.annual) == "Start the free trial")
        #expect(
            PlanCopy.priceLine(SubscriptionOffer.double.annual)
                == "2 weeks free, then $59.99 a year"
        )
        #expect(
            PlanCopy.priceLine(SubscriptionOffer.double.monthly)
                == "2 weeks free, then $5.99 a month"
        )
    }
}

// MARK: - Restore

@Suite("Restore")
struct SubscriptionRestoreTests {

    @Test("restore syncs and then asks the server, rather than deciding anything itself")
    @MainActor
    func restoreAsksTheServer() async {
        let store = FakeStore()
        let reads = Counter()
        let model = makeModel(store: store) {
            _ = await reads.bump()
            return await household("subscribed")
        }

        await model.restore()

        #expect(await store.restores == 1)
        #expect(await reads.read() >= 1, "restore must re-read the entitlement from the server")
        #expect(model.household?.isSubscribed == true)
        #expect(model.notice == nil)
        #expect(model.isRestoring == false)
    }

    @Test("a restore that finds a subscription leaves the parent something to read")
    @MainActor
    func aSuccessfulRestoreIsNotSilent() async {
        // The dead end this pins: restore succeeds, `household` flips to subscribed, `canBuy`
        // correctly goes false — and with `purchase` still `.idle` the paywall used to render a
        // greyed-out "Start the free trial" and no sentence at all. Nothing said what happened.
        let subscribed = Counter()
        let model = makeModel(store: FakeStore()) {
            await household(await subscribed.read() > 0 ? "subscribed" : "free")
        }
        await model.load()
        #expect(model.canBuy)

        _ = await subscribed.bump()
        await model.restore()

        #expect(model.household?.isSubscribed == true)
        #expect(model.canBuy == false)
        // The paywall keys its "You're subscribed." terminal state off exactly this pair, so a
        // parent is told rather than left with a dead control.
        #expect(model.purchase == .idle || model.purchase == .subscribed)
        #expect(
            model.notice == nil,
            "a successful restore should not also report a failure notice"
        )
    }

    @Test("a restore that finds nothing says so plainly rather than failing")
    @MainActor
    func nothingToRestore() async {
        let model = makeModel(store: FakeStore()) { await household("free") }
        await model.restore()

        #expect(model.notice?.hasPrefix("Nothing has arrived yet.") == true)
        // And it does not claim anything about what Apple holds — the client cannot see that.
        #expect(model.notice?.contains("Apple Account") == false)
        #expect(model.household?.isSubscribed == false)
    }

    @Test("a refused sync is reported as a sentence and changes no entitlement")
    @MainActor
    func aRefusedSyncIsASentence() async {
        let store = FakeStore(restoreResult: .failure(.storeKit("The App Store couldn't be reached.")))
        let model = makeModel(store: store) { await household("free") }

        await model.restore()

        #expect(model.notice == "The App Store couldn't be reached.")
        #expect(model.isRestoring == false)
    }

    @Test("a second tap while restoring does not start a second sync")
    @MainActor
    func restoreIsNotReentrant() async {
        let store = FakeStore()
        let model = makeModel(store: store) { await household("free") }

        async let first: Void = model.restore()
        async let second: Void = model.restore()
        _ = await (first, second)

        // **Exactly one.** `isRestoring` is set before the first suspension, so the second call
        // returns at the guard. `<= 2` was the original assertion here and it could not fail,
        // which made it a test of nothing.
        #expect(await store.restores == 1)
    }
}

// MARK: - The listener's counter

/// The split between "somebody came back to the app" and "a transaction arrived".
///
/// **This is the guard for the worst bug this branch had.** One counter used to serve both
/// `SubscriptionCenter.refresh()` — which `OnboardingGate` calls on every foreground — and the
/// `Transaction.updates` drain, so any foreground reached `transactionArrived()` and, from
/// `.awaitingApproval`, ran the confirmation window to its terminal "Your subscription is being
/// confirmed. There's nothing else you need to do." Nobody had approved anything.
///
/// `theListenerIsWired` does not cover this and cannot: it greps the source for
/// `SubscriptionStore.drain(Transaction.updates)` and `await self?.refresh()`, and **both
/// substrings survive** the one edit that reintroduces the bug — moving `transactionDelivered()`
/// inside `refresh()`. These are behavioural.
@Suite("The transaction counter, and what may bump it")
struct SubscriptionCenterTests {

    @MainActor
    private func center(answering status: Int, body: String = "{}") -> (SubscriptionCenter, StubPerformer) {
        let performer = StubPerformer()
        performer.on("families/me") { _ in (Data(body.utf8), status) }
        let api = APIClient(
            baseURL: URL(string: "https://example.invalid")!,
            performer: performer,
            tokens: InMemoryTokenStore()
        )
        return (SubscriptionCenter(testing: api), performer)
    }

    @Test("a foreground re-check asks the server and does not look like a transaction")
    @MainActor
    func aSuccessfulRefreshDoesNotBump() async {
        let household = """
        {"family_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","tier":"subscribed",
         "guardians":[],"pending_invites":[]}
        """
        let (center, performer) = center(answering: 200, body: household)
        #expect(center.transactionRevision == 0)

        await center.refresh()
        await center.refresh()

        // It did ask — the foreground re-check is a real server read, not a no-op.
        #expect(performer.count(for: "families/me") == 2)
        // And it did not announce a transaction, because none arrived.
        #expect(
            center.transactionRevision == 0,
            "a foreground re-check bumped the transaction counter"
        )
    }

    @Test("a refresh whose request fails also does not bump")
    @MainActor
    func aFailedRefreshDoesNotBump() async {
        // The original bug bumped unconditionally — including when the read threw, which is the
        // worse half: the app announced a change it had just failed to learn about.
        let (center, _) = center(answering: 500)

        await center.refresh()

        #expect(
            center.transactionRevision == 0,
            "a failed refresh bumped the transaction counter"
        )
    }

    @Test("a center with no client refuses rather than announcing anything")
    @MainActor
    func aRefreshBeforeStartIsInert() async {
        let (center, performer) = center(answering: 200)
        _ = performer
        // `start(api:)` has not run in production terms; this instance has a client but no
        // listener, and the invariant under test is that neither path invents a transaction.
        await center.refresh()
        #expect(center.transactionRevision == 0)
    }
}

// MARK: - Prices, and the absence of literals

@Suite("Prices, which are never written down")
struct SubscriptionPriceTests {

    @Test("the saving is computed from the two prices, not written down")
    func theSavingIsArithmetic() {
        // Twelve at 5.99 is 71.88 against 59.99 — 1.98 months, which is the "two months free" D1
        // describes and is deliberately not exactly two.
        #expect(AnnualSaving.describe(.double) == "Two months free")
    }

    @Test("a storefront where annual is not cheaper claims nothing")
    func noSavingMeansNoClaim() {
        let format = Decimal.FormatStyle.Currency.currency(code: "USD")
        #expect(
            AnnualSaving.describe(
                annualPrice: Decimal(string: "71.88")!,
                monthlyPrice: Decimal(string: "5.99")!, format: format
            ) == nil
        )
        #expect(
            AnnualSaving.describe(
                annualPrice: Decimal(string: "80.00")!,
                monthlyPrice: Decimal(string: "5.99")!, format: format
            ) == nil
        )
    }

    @Test("a saving that is not a whole number of months is rendered as money")
    func anAwkwardSavingBecomesMoney() {
        let saving = AnnualSaving.describe(
            annualPrice: Decimal(string: "50.00")!,
            monthlyPrice: Decimal(string: "5.99")!,
            format: .currency(code: "USD")
        )
        // 21.88 saved is 3.65 months — not a clean claim, so it says the money instead.
        #expect(saving?.hasPrefix("Save ") == true)
        #expect(saving?.contains("21.88") == true)
    }

    @Test("the saving is formatted in the product's currency, not the device's")
    func theSavingFollowsTheStorefront() {
        let saving = AnnualSaving.describe(
            annualPrice: Decimal(string: "50.00")!,
            monthlyPrice: Decimal(string: "5.99")!,
            format: .currency(code: "JPY")
        )
        #expect(saving?.contains("$") == false)
    }

    @Test("a configured trial is not shown to somebody Apple would not grant it to")
    func anIneligibleAccountIsPromisedNoTrial() {
        let twoWeeks = SubscriptionPeriodValue(value: 2, unit: .week)

        // Configured and eligible: shown.
        #expect(TrialRule.resolve(configured: twoWeeks, eligible: true) == twoWeeks)
        // Configured but already spent — one group, so trialling the monthly spends the annual's
        // too. Promising it would be a false claim about money.
        #expect(TrialRule.resolve(configured: twoWeeks, eligible: false) == nil)
        // Not configured at all: nothing to promise either way.
        #expect(TrialRule.resolve(configured: nil, eligible: true) == nil)
        #expect(TrialRule.resolve(configured: nil, eligible: false) == nil)
    }

    @Test("periods are worded from the product's own numbers")
    func periodWording() {
        #expect(SubscriptionPeriodValue(value: 2, unit: .week).phrase == "2 weeks")
        #expect(SubscriptionPeriodValue(value: 1, unit: .month).phrase == "1 month")
        #expect(SubscriptionPeriodValue(value: 1, unit: .year).cadence == "a year")
        #expect(SubscriptionPeriodValue(value: 1, unit: .month).cadence == "a month")
        #expect(SubscriptionPeriodValue(value: 3, unit: .month).cadence == "every 3 months")
    }

    /// **This is the test for break-test #4**, and it is a source assertion rather than a
    /// behavioural one on purpose: a hardcoded `"$5.99"` renders perfectly and is wrong in every
    /// other currency, so nothing a running screen does can catch it.
    @Test("no currency literal appears anywhere in the subscription source")
    func noCurrencyLiterals() throws {
        for file in try subscriptionSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Comments are where the prices are allowed to be discussed.
                if code.hasPrefix("//") || code.hasPrefix("*") { continue }
                // **Any currency symbol next to a digit inside a string literal**, not just the
                // two USD strings D1 happens to name. The rule is "no price is ever written down
                // in Swift" — a check that only knew `$5.99` would have passed a hardcoded
                // `"£4.99"` or `"€59,99"`, which is the same defect in the storefront that would
                // actually see it.
                for match in code.matches(of: /"[^"]*[$£€¥₩₹][0-9][^"]*"/) {
                    Issue.record(
                        "a currency literal \(match.output) at \(file.lastPathComponent):\(index + 1)"
                    )
                }
            }
        }
    }

    /// Review requires Terms of Use and a Privacy Policy on any screen selling a subscription, and
    /// `LegalLinks` renders each only when its key resolves to a non-empty string. So a build whose
    /// plumbing is missing shows a paywall with no links and is rejected — silently, because
    /// nothing crashes and nothing looks wrong.
    ///
    /// This pins the half that is in the repository. **The half that is not is `Config.xcconfig`
    /// itself, which is gitignored** — a developer whose copy predates this phase resolves both
    /// `$(TERMS_URL)` and `$(PRIVACY_URL)` to empty and gets exactly that silent build. The two
    /// keys are in `Config.xcconfig.example`; copying them across is a manual step and this test
    /// cannot see whether it was done.
    @Test("both Info.plist files carry the legal-link keys the paywall reads")
    func theLegalLinkKeysArePlumbedThrough() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()

        for name in ["Info.plist", "Info-Debug.plist"] {
            let plist = try String(
                contentsOf: root.appendingPathComponent(name), encoding: .utf8
            )
            for key in ["TERMS_URL", "PRIVACY_URL"] {
                #expect(
                    plist.contains("<key>\(key)</key>"),
                    "\(name) does not expose \(key), so the paywall can never show that link"
                )
                #expect(
                    plist.contains("$(\(key))"),
                    "\(name) declares \(key) but does not reference the build setting"
                )
            }
        }

        // And the example config a new checkout copies from must define them, with the `//`
        // escape — an unescaped URL truncates at `https:` and the link points nowhere.
        let example = try String(
            contentsOf: root.appendingPathComponent("Config.xcconfig.example"), encoding: .utf8
        )
        #expect(example.contains("TERMS_URL"))
        #expect(example.contains("PRIVACY_URL"))
        #expect(
            example.contains("https:$()/$()/"),
            "a URL in an xcconfig must escape `//` or it is parsed as a comment"
        )
    }

    /// **This is the test for break-test #1.** Replacing the token with a fresh UUID changes this
    /// line, and a behavioural test alone could not see past the boundary to catch it.
    @Test("the purchase option is the family id and nothing else")
    func theTokenIsNotSubstituted() throws {
        let store = try subscriptionSources()
            .first { $0.lastPathComponent == "SubscriptionStore.swift" }
        let source = try String(contentsOf: try #require(store), encoding: .utf8)

        let calls = source.components(separatedBy: ".appAccountToken(").dropFirst()
        #expect(calls.count == 1, "there should be exactly one appAccountToken call site")
        for call in calls {
            let argument = call.prefix { $0 != ")" }
            #expect(
                argument == "familyID",
                "appAccountToken must carry the household, not \(argument)"
            )
        }
        #expect(source.contains("UUID()") == false, "the store must never mint an identifier")
    }

    /// **Added because break-test 3 failed nothing.**
    ///
    /// Removing the `Transaction.updates` drain from `SubscriptionCenter` left the whole suite
    /// green: the tests that would have caught it — the Ask-to-Buy approval and the interrupted
    /// purchase — live in `SubscriptionStoreKitTests`, which cannot run on this machine. A silent
    /// pass on a deleted listener is worse than no test, because losing it means every purchase
    /// completed in the background is never finished and Apple redelivers it forever.
    ///
    /// A source assertion, like the `appAccountToken` one above, and honest about being one: it
    /// proves the listener is wired, not that a transaction ever reached it.
    @Test("the transaction listener is wired to Transaction.updates at launch")
    func theListenerIsWired() throws {
        let center = try subscriptionSources()
            .first { $0.lastPathComponent == "SubscriptionCenter.swift" }
        // **Comments stripped first.** A plain `contains` over raw text stays green when the
        // listener is commented out, which is one keystroke away from deleting it.
        let source = Self.executableLines(of: try String(contentsOf: try #require(center), encoding: .utf8))
        #expect(
            source.contains("SubscriptionStore.drain(Transaction.updates)"),
            "SubscriptionCenter must drain Transaction.updates"
        )
        // And it is the entitlement it refreshes, rather than a tier written locally.
        #expect(source.contains("await self?.refresh()"))
        // **`refresh()` must not announce a transaction.** Substring presence alone cannot see
        // this: moving `transactionDelivered()` inside `refresh()` leaves every string above
        // intact. `SubscriptionCenterTests` pins the behaviour; this pins the shape, because the
        // two fail differently and the source one names the edit.
        if let body = source.range(of: "func refresh() async {") {
            let after = source[body.upperBound...]
            let end = after.range(of: "\n    }")?.lowerBound ?? after.endIndex
            #expect(
                !after[..<end].contains("transactionDelivered"),
                "refresh() bumps the transaction counter — that is the foreground bug returning"
            )
        }

        let gate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Rascal/Onboarding/OnboardingGate.swift")
        let gateSource = Self.executableLines(of: try String(contentsOf: gate, encoding: .utf8))
        #expect(
            gateSource.contains("SubscriptionCenter.shared.start(api:"),
            "the listener must be started at launch, above RootView's .id(child.id)"
        )
        #expect(
            gateSource.contains("SubscriptionCenter.shared.refresh()"),
            "the entitlement must be re-checked on foreground"
        )
    }

    /// Everything in a Swift file that is not a comment line. Crude — it does not understand
    /// block comments or trailing `//` — and enough to stop a source assertion passing on prose.
    static func executableLines(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func subscriptionSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RascalTests
            .deletingLastPathComponent()      // Rascal
            .appendingPathComponent("Rascal/Subscription")
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the subscription sources moved and this test stopped looking")
        return files
    }
}
