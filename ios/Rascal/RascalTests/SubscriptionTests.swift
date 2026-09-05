import Foundation
import Testing

@testable import Rascal

// MARK: - Doubles

/// A counter the drain callback and the household reader can bump from any isolation.
/// A one-shot gate, so a test can park an injected read mid-flight and run something else on the
/// model while it is parked.
///
/// Exists because `load()`'s prologue and its publish happen either side of an `await`, and the
/// only defect that reaches the publish-site guard is one that lands inside that window. A test
/// that cannot hold the window open cannot tell the two apart — which is how the first version of
/// `loadReconcilesTheChannelsWithWhatItPublishes` passed against a deliberately broken model.
private actor Gate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var arrived = false

    /// Called from inside the parked read.
    func wait() async {
        arrived = true
        arrival?.resume()
        arrival = nil
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// Resumes once the read has actually parked, so the race is staged rather than hoped for.
    func readyToRelease() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

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
    /// Per-call restore results, the way `outcomes` already works for `purchase`. Needed because a
    /// standing confirmation from a *previous* successful restore is the state that matters, and it
    /// takes two runs with different results to reach it.
    private var restoreResults: [Result<Void, SubscriptionStoreError>]

    private(set) var purchases: [(plan: SubscriptionPlan, familyID: UUID)] = []
    private(set) var restores = 0

    /// When set, `purchase` parks here until `release()` — which is the only way to observe the
    /// model *during* a purchase rather than after one.
    private var holdPurchase = false
    private var held: CheckedContinuation<Void, Never>?
    /// What `currentEntitlement()` hands over — the JWS the device holds, or nothing. Counted,
    /// because the phase 140 tests assert the model *asked* as much as what it did with the answer.
    private let entitlement: String?
    private(set) var entitlementReads = 0

    init(
        offer: SubscriptionOffer? = .double,
        outcomes: [Result<PurchaseOutcome, SubscriptionStoreError>] = [.success(.purchased)],
        restoreResult: Result<Void, SubscriptionStoreError> = .success(()),
        restoreResults: [Result<Void, SubscriptionStoreError>] = [],
        holdPurchase: Bool = false,
        entitlement: String? = nil
    ) {
        self.offer = offer
        self.outcomes = outcomes
        self.restoreResult = restoreResult
        self.restoreResults = restoreResults
        self.holdPurchase = holdPurchase
        self.entitlement = entitlement
    }

    func currentEntitlement() async -> String? {
        entitlementReads += 1
        return entitlement
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
        try (restoreResults.isEmpty ? restoreResult : restoreResults.removeFirst()).get()
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
        // `tier` and `access` agree in every case this suite exercises. They are separate fields
        // because they can disagree — a household on the free tier may still be inside its trial —
        // and nothing here depends on that.
        access: tier == "subscribed" ? .subscribed : .free,
        lapsedAt: nil,
        plan: nil,
        billingRetry: nil,
        isPayer: nil,
        entitled: nil,
        entitlementSource: nil,
        guardians: [
            GuardianSummary(
                userId: UUID(), displayName: "Travis", role: "parent",
                grantedAt: .now, isYou: true
            )
        ],
        pendingInvites: []
    )
}

/// A household the server entitles by an admin grant: `tier` still `free`, `access` reading
/// `subscribed` by the server's deliberate choice, and `entitlement_source` the only field that
/// says why. The pairing `tier` and `access` cannot describe between them.
@MainActor
private func grantedHousehold(id: UUID = UUID()) -> FamilySummary {
    FamilySummary(
        familyId: id,
        tier: "free",
        access: .subscribed,
        lapsedAt: nil,
        plan: nil,
        billingRetry: nil,
        isPayer: nil,
        entitled: true,
        entitlementSource: "grant",
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

    @Test("a restore that finds a membership says so, in its own channel")
    @MainActor
    func aFoundRestoreWritesAConfirmation() async {
        // **Phase 126.** Settings does not dismiss on a successful restore — the parent stays on
        // the card they were reading — so the row spins and then stops, and without a sentence
        // that is indistinguishable from a run that failed. `notice` cannot carry it:
        // `aSuccessfulRestoreIsNotSilent` above asserts `notice == nil` on this exact path, and it
        // is right to, because `notice` means "something to tell you that went not-quite-right".
        let subscribed = Counter()
        let model = makeModel(store: FakeStore()) {
            await household(await subscribed.read() > 0 ? "subscribed" : "free")
        }
        await model.load()
        _ = await subscribed.bump()

        await model.restore()

        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(model.notice == nil, "the two channels are exclusive; a success is not a notice")
    }

    @Test("a restore that finds nothing writes no confirmation")
    @MainActor
    func anEmptyRestoreWritesNoConfirmation() async {
        let model = makeModel(store: FakeStore()) { await household("free") }

        await model.restore()

        #expect(model.restoreConfirmation == nil)
        #expect(model.notice != nil, "the parent is still told something")
    }

    @Test("a load never publishes a household its own channels contradict")
    @MainActor
    func loadReconcilesTheChannelsWithWhatItPublishes() async {
        // **The last publish site that reconciled nothing, and the race has to be staged to reach
        // it.** `load()` clears both channels in its *prologue* — so a fresh call is covered by
        // that and the publish-site guard is never needed. The uncovered case is a `restore()` that
        // completes *inside* load's await window: the prologue has already run, the restore sets
        // `restoreConfirmation`, and then load publishes a household read that began before the
        // restore proved anything. The card renders *Free* under "Found it. Your membership is
        // active."
        //
        // **Written after break-test 20 came back green against a naive version of this test**,
        // which called `load()` fresh and was satisfied by the prologue — the same shape as
        // `aSecondRestoreClearsTheConfirmation` being satisfied by a clear it does not name.
        let gate = Gate()
        let reads = Counter()
        let model = makeModel(store: FakeStore()) {
            let n = await reads.bump()
            // Read 1 is load's: park it mid-flight, and answer `free` when finally released.
            if n == 1 {
                await gate.wait()
                return await household("free")
            }
            // Everything after is the restore's, which proves the household subscribed.
            return await household("subscribed")
        }

        async let loading: Void = model.load()
        await gate.readyToRelease()

        // Runs while `load()` is parked past its prologue.
        await model.restore()
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)

        await gate.open()
        await loading

        #expect(model.household?.isSubscribed == false, "load published the stale read, as it must")
        #expect(
            model.restoreConfirmation == nil,
            "a free household must not be published under 'your membership is active'"
        )
    }

    @Test("a refused restore does not leave the last run's confirmation standing")
    @MainActor
    func aRefusedRestoreClearsAStandingConfirmation() async {
        // **The case `aSecondRestoreClearsTheConfirmation` below looks like it covers and does
        // not.** That test's second run reaches `refreshHousehold()`, whose subscribed→free guard
        // clears the confirmation on its own — so it stays green with `restore()`'s prologue clear
        // deleted. This one cannot: a refused `AppStore.sync()` returns before the poll, so the
        // transition guard never runs and the prologue is the only thing that clears.
        //
        // What that protects: Settings does not dismiss on success, so the confirmation is still on
        // the card when the parent taps Restore again. `SubscriptionSection` renders
        // `restoreConfirmation ?? notice` — so without the prologue the card keeps saying "Found
        // it. Your membership is active." and the App Store error is never shown at all.
        let store = FakeStore(restoreResults: [
            .success(()),
            .failure(.storeKit("The App Store couldn't be reached.")),
        ])
        let model = makeModel(store: store) { await household("subscribed") }

        await model.restore()
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)

        await model.restore()

        #expect(
            model.restoreConfirmation == nil,
            "the card must show the refusal, not the previous run's success"
        )
        #expect(model.notice == "The App Store couldn't be reached.")
        #expect(model.household?.isSubscribed == true, "a refused sync changes no entitlement")
    }

    /// **Covers the *end state* of an empty second run, not the prologue's timing.** The clear this
    /// lands on is `refreshHousehold()`'s subscribed→free transition, not `restore()`'s prologue —
    /// see `aRefusedRestoreClearsAStandingConfirmation` above for the one that pins the prologue.
    @Test("a second restore clears the first one's confirmation before it has an answer")
    @MainActor
    func aSecondRestoreClearsTheConfirmation() async {
        // Without this, a run that came back empty would sit under a "your membership is here"
        // left over from the run before it — two sentences contradicting each other on one card.
        let subscribed = Counter()
        let model = makeModel(store: FakeStore()) {
            await household(await subscribed.read() > 0 ? "free" : "subscribed")
        }
        await model.restore()
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)

        _ = await subscribed.bump()
        await model.restore()

        #expect(model.restoreConfirmation == nil)
    }

    @Test("opening either surface clears a confirmation left from last time")
    @MainActor
    func loadClearsTheConfirmation() async {
        let subscribed = Counter()
        let model = makeModel(store: FakeStore()) {
            await household(await subscribed.read() > 0 ? "subscribed" : "free")
        }
        await model.load()
        _ = await subscribed.bump()
        await model.restore()
        #expect(model.restoreConfirmation != nil)

        await model.load()

        #expect(model.restoreConfirmation == nil, "yesterday's answer is not a statement about now")
    }

    @Test("a restore whose window closed and then found a membership still says so")
    @MainActor
    func aLateRestoreThatFindsOneWritesAConfirmation() async {
        // **The slow path, which the fast one does not cover.** `restoreSchedule` is four reads;
        // exhausting it returns `.late`, and `restore()` then calls `refreshHousehold()` for a
        // fifth. If *that* read says subscribed, the parent's answer arrived — just not inside the
        // window — and the card must say the same thing it would have said quickly. Without this
        // the branch is written and never executed by any test.
        let reads = Counter()
        let model = makeModel(store: FakeStore()) {
            // free for the four polls, subscribed for the refresh that follows
            await household(await reads.bump() > 4 ? "subscribed" : "free")
        }

        await model.restore()

        #expect(await reads.read() == 5, "four polls then one refresh — the .late path, not the fast one")
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(model.notice == nil, "arriving late is not a failure and must not read as one")
        #expect(model.household?.isSubscribed == true)
    }

    @Test("a restore whose window closed and whose confirming read failed claims nothing")
    @MainActor
    func aLateRestoreWithAFailedRefreshClaimsNothing() async {
        // **The stale-household defect.** `refreshHousehold()` returns early on a throwing read,
        // leaving `household` holding whatever it held before. A household that was subscribed and
        // has since lapsed would then be told "your membership is active" on the strength of a
        // summary this restore never confirmed — the device deciding entitlement off cached state,
        // which is exactly what D5 forbids.
        let reads = Counter()
        let model = makeModel(store: FakeStore()) {
            // One good read to seed a subscribed household, then the four polls report free, then
            // the confirming refresh throws.
            let n = await reads.bump()
            if n == 1 { return await household("subscribed") }
            if n <= 5 { return await household("free") }
            throw URLError(.timedOut)
        }
        await model.load()
        #expect(model.household?.isSubscribed == true)

        await model.restore()

        #expect(
            model.restoreConfirmation == nil,
            "a read that failed is not a membership found — the summary is stale, not confirmed"
        )
        // **And it says nothing in the other direction either**, which round 4 corrected. The
        // household on file is subscribed; writing "Nothing has arrived yet" under a card whose
        // status row reads *Subscribed* is the same contradiction, inverted. A restore whose
        // confirming read failed proved nothing either way, so it claims nothing either way.
        #expect(model.notice == nil, "a failed read is not evidence that nothing arrived")
        #expect(model.household?.isSubscribed == true, "the card still shows what it already knew")
    }

    @Test("a membership that goes away takes its confirmation with it")
    @MainActor
    func aLapseClearsTheConfirmation() async {
        // Restore succeeds, the card says so — then a refund or a lapse arrives on
        // `Transaction.updates` or on foreground. Leaving the sentence up makes the card
        // contradict itself, with the stale half being the reassuring one.
        let subscribed = Counter()
        let model = makeModel(store: FakeStore()) {
            await household(await subscribed.read() == 1 ? "subscribed" : "free")
        }
        _ = await subscribed.bump()
        await model.restore()
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)

        _ = await subscribed.bump()
        await model.refreshHousehold()

        #expect(model.household?.isSubscribed == false)
        #expect(model.restoreConfirmation == nil, "the card must not still say the membership is active")
    }

    @Test("an approval that lands after a fruitless restore clears the not-found notice")
    @MainActor
    func anApprovalClearsTheNotice() async {
        // **The fourth writer to `household`, and the one the transition guards cannot see.**
        // Neither restore control consults `purchase`, so an Ask-to-Buy parent can tap Restore
        // while the approval is outstanding, get "Nothing has arrived yet", and then have the
        // approval land through `confirm()` rather than through `refreshHousehold()`. Without the
        // clear there, the card renders *Subscribed* with *nothing has arrived* underneath it.
        let subscribed = Counter()
        let model = makeModel(store: FakeStore()) {
            await household(await subscribed.read() > 0 ? "subscribed" : "free")
        }
        await model.restore()
        #expect(model.notice != nil, "the restore found nothing, and said so")

        _ = await subscribed.bump()
        await model.confirm()

        #expect(model.purchase == .subscribed)
        #expect(model.household?.isSubscribed == true)
        #expect(model.notice == nil, "the card must not say nothing arrived above a subscribed row")
    }

    @Test("a membership that arrives after the window takes the not-found notice with it")
    @MainActor
    func aLateArrivalClearsTheNotice() async {
        // **The mirror of `aLapseClearsTheConfirmation`, and the direction round 2 missed.** The
        // window closes, the card says "Nothing has arrived yet" — and then the webhook lands, a
        // second or two late, which is the ordinary shape of a late confirmation. Without this the
        // status row reads "Everything open" with "Nothing has arrived yet" underneath it.
        let subscribed = Counter()
        let model = makeModel(store: FakeStore()) {
            await household(await subscribed.read() > 0 ? "subscribed" : "free")
        }
        await model.restore()
        #expect(model.notice != nil)

        _ = await subscribed.bump()
        await model.refreshHousehold()

        #expect(model.household?.isSubscribed == true)
        #expect(model.notice == nil, "the card must not still say nothing has arrived")
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
        // A store with nothing to hand over: these tests are about `refresh()`, which never asks
        // it, and `ReconciliationTests` below is where the store gets a receipt.
        return (SubscriptionCenter(testing: api, store: FakeStore()), performer)
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

// MARK: - The receipt reaches the server without a tap

/// **Phase 145, and the gap it closes was found by reading rather than by a parent.** Until now
/// the JWS the device holds was submitted from exactly two places, both behind a tap: a purchase's
/// confirmation and a restore. A purchase whose submission failed while Apple's webhook was also
/// lost, or a renewal landing while the webhook was down, left the server never hearing about a
/// receipt the phone was carrying — and a household running out its trial and reading *Free* while
/// Apple charged. `SubscriptionCenter.reconcile()` runs the same hand-over at launch and on every
/// drained transaction; these pin what it sends, what it refuses to send, and that it says nothing.
@Suite("Phase 145 — the receipt the device holds reaches the server without a tap")
struct ReconciliationTests {

    private static let familyID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

    /// A household in its trial: `tier` free, `access` trial, no grant. Not a member, which is the
    /// shape the defect lives in.
    private static let trialHousehold = """
    {"family_id":"\(familyID)","tier":"free","access":"trial","entitled":true,
     "entitlement_source":"trial","guardians":[],"pending_invites":[]}
    """
    private static let subscribedHousehold = """
    {"family_id":"\(familyID)","tier":"subscribed","access":"subscribed","entitled":true,
     "entitlement_source":"receipt","guardians":[],"pending_invites":[]}
    """
    /// Complimentary access: `tier` still free, and `isMember` because of the grant alone.
    private static let grantedHousehold = """
    {"family_id":"\(familyID)","tier":"free","access":"subscribed","entitled":true,
     "entitlement_source":"grant","guardians":[],"pending_invites":[]}
    """
    private static func submission(of household: String, status: String = "tier:subscribed") -> String {
        #"{"status":"\#(status)","family":\#(household)}"#
    }
    private static let conflictEnvelope = """
    {"error":{"code":"conflict","message":"This transaction belongs to a different household.","field":null}}
    """

    /// A center with a scripted server, a store, and a session — or, when `signedIn` is false, the
    /// client a fresh install holds, with no tokens at all.
    @MainActor
    private func center(
        household: String,
        householdStatus: Int = 200,
        submission: String = "{}",
        submissionStatus: Int = 200,
        store: FakeStore,
        signedIn: Bool = true
    ) -> (SubscriptionCenter, StubPerformer) {
        let performer = StubPerformer()
        // Registered in this order on purpose: `StubPerformer` matches by `contains` and the
        // *last* matching rule wins, so the transactions route — whose path also contains
        // `families/me` — has to be registered after the household read to be the one that
        // answers a POST.
        performer.on("families/me") { _ in (Data(household.utf8), householdStatus) }
        performer.on("families/me/transactions") { _ in (Data(submission.utf8), submissionStatus) }
        let tokens = signedIn
            ? InMemoryTokenStore(TokenPair(accessToken: "access", refreshToken: "refresh"))
            : InMemoryTokenStore()
        let api = APIClient(
            baseURL: URL(string: "https://example.invalid")!,
            performer: performer,
            tokens: tokens
        )
        return (SubscriptionCenter(testing: api, store: store), performer)
    }

    private func posts(_ performer: StubPerformer) -> [URLRequest] {
        performer.requests.filter {
            $0.httpMethod == "POST" && ($0.url?.path().hasSuffix("families/me/transactions") ?? false)
        }
    }

    private func reads(_ performer: StubPerformer) -> Int {
        performer.requests.filter {
            $0.httpMethod == "GET" && ($0.url?.path().hasSuffix("families/me") ?? false)
        }.count
    }

    @Test("a household the server does not call a member gets the receipt the device holds")
    @MainActor
    func submitsTheReceiptForANonMember() async throws {
        let store = FakeStore(entitlement: "jws.apple.signed")
        let (center, performer) = center(
            household: Self.trialHousehold,
            submission: Self.submission(of: Self.subscribedHousehold),
            store: store
        )

        await center.reconcile()

        let sent = posts(performer)
        #expect(sent.count == 1, "the receipt was not handed over")
        let body = try #require(sent.first?.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["signed_transaction"] as? String == "jws.apple.signed")
        let asked = await store.entitlementReads
        #expect(asked == 1)
        // The server now calls the household subscribed, so open screens are told to look —
        #expect(center.householdRevision == 1, "a subscribed answer must wake the open screens")
        // — and told through the right door. Nothing came off `Transaction.updates`.
        #expect(
            center.transactionRevision == 0,
            "a reconciled receipt announced itself as a transaction — a launch would look like an approval"
        )
    }

    @Test(
        "a member is left alone — no receipt is offered for what the server already grants",
        arguments: [subscribedHousehold, grantedHousehold]
    )
    @MainActor
    func aMemberIsLeftAlone(household: String) async {
        let store = FakeStore(entitlement: "jws.apple.signed")
        let (center, performer) = center(
            household: household,
            submission: Self.submission(of: Self.subscribedHousehold),
            store: store
        )

        await center.reconcile()

        #expect(reads(performer) == 1, "the server is asked once, so the answer can decide")
        #expect(posts(performer).isEmpty, "a member's receipt was submitted")
        // Not even asked for: the store is only consulted once there is something to reconcile.
        let asked = await store.entitlementReads
        #expect(asked == 0)
        #expect(center.householdRevision == 0)
        #expect(center.transactionRevision == 0)
    }

    @Test("no receipt on the device means nothing is sent, and nothing is announced")
    @MainActor
    func noReceiptMeansNothingIsSent() async {
        let store = FakeStore(entitlement: nil)
        let (center, performer) = center(household: Self.trialHousehold, store: store)

        await center.reconcile()

        #expect(reads(performer) == 1)
        #expect(posts(performer).isEmpty, "a POST with no receipt in it")
        let asked = await store.entitlementReads
        #expect(asked == 1, "the store was the step that stopped this, so it must have been asked")
        #expect(center.householdRevision == 0)
        #expect(center.transactionRevision == 0)
    }

    /// **Every refusal is silent, and the `409` is the one that matters.** The server saying the
    /// receipt belongs to a different household is the refusal `SubscriptionModel` turns into a
    /// sentence when a parent taps Buy or Restore — and exactly the one a launch must not, because
    /// nobody did anything and there is nothing on screen for a sentence to be about.
    @Test(
        "a refused submission is swallowed whole — no throw, no state, no counter",
        arguments: [
            (409, conflictEnvelope),
            (422, #"{"error":{"code":"validation_failed","message":"not signed for this bundle","field":"signed_transaction"}}"#),
            (409, "{}"),
            (404, "{}"),
            (500, "not json at all"),
        ]
    )
    @MainActor
    func aRefusalIsSilent(status: Int, body: String) async {
        let store = FakeStore(entitlement: "jws.bought.under.another.account")
        let (center, performer) = center(
            household: Self.trialHousehold,
            submission: body,
            submissionStatus: status,
            store: store
        )

        // The assertion is partly that this line returns at all: `reconcile()` does not throw,
        // so a refusal that escaped would be a crash rather than a failed expectation.
        await center.reconcile()

        #expect(posts(performer).count == 1, "\(status) was never even attempted")
        #expect(center.householdRevision == 0, "\(status) woke the screens over nothing")
        #expect(center.transactionRevision == 0, "\(status) was announced as a transaction")
    }

    @Test("a server that takes the receipt and still says free announces nothing")
    @MainActor
    func aFreeAnswerSignalsNothing() async {
        // A `200` whose household still reads `free` — a receipt for an expired subscription,
        // say, which the server verified and had no reason to promote on.
        let store = FakeStore(entitlement: "jws.of.a.lapsed.year")
        let (center, performer) = center(
            household: Self.trialHousehold,
            submission: Self.submission(of: Self.trialHousehold, status: "ignored:not-active"),
            store: store
        )

        await center.reconcile()

        #expect(posts(performer).count == 1)
        #expect(center.householdRevision == 0, "nothing changed, so there is nothing to re-read")
        #expect(center.transactionRevision == 0)
    }

    @Test("a household read that fails sends nothing rather than guessing")
    @MainActor
    func aFailedReadSendsNothing() async {
        let store = FakeStore(entitlement: "jws.apple.signed")
        let (center, performer) = center(
            household: #"{"error":{"code":"internal_error","message":"bad minute","field":null}}"#,
            householdStatus: 500,
            store: store
        )

        await center.reconcile()

        #expect(posts(performer).isEmpty, "the server was not asked, so it must not be told")
        let asked = await store.entitlementReads
        #expect(asked == 0)
        #expect(center.householdRevision == 0)
    }

    /// `start(api:)` runs before `OnboardingGate` has resolved a session — deliberately, so the
    /// drain is reading before any paywall exists — which means on a fresh install the launch
    /// reconciliation meets a client with no tokens. It must notice and leave, not send a `GET`
    /// that can only `401`.
    @Test("before there is a session, nothing is asked of anybody")
    @MainActor
    func nothingIsAskedBeforeSignIn() async {
        let store = FakeStore(entitlement: "jws.apple.signed")
        let (center, performer) = center(household: Self.trialHousehold, store: store, signedIn: false)

        await center.reconcile()

        #expect(performer.requests.isEmpty, "a request went out with no session behind it")
        let asked = await store.entitlementReads
        #expect(asked == 0)
        #expect(center.householdRevision == 0)
        #expect(center.transactionRevision == 0)
    }

    /// The counter split, extended to the new counter. `SubscriptionCenterTests` pins that
    /// `refresh()` never bumps `transactionRevision`; this pins that it never bumps
    /// `householdRevision` either, because a foreground is a re-read and not news.
    @Test("refresh() still bumps neither counter, whatever the server says")
    @MainActor
    func refreshBumpsNeitherCounter() async {
        let store = FakeStore(entitlement: "jws.apple.signed")
        let (center, performer) = center(household: Self.subscribedHousehold, store: store)

        await center.refresh()
        await center.refresh()

        #expect(reads(performer) == 2, "the foreground re-check is a real read")
        #expect(posts(performer).isEmpty, "refresh() is a read, never a submission")
        #expect(center.transactionRevision == 0, "the foreground bug returning")
        #expect(center.householdRevision == 0, "the foreground bug returning by the new door")
    }

    /// The drain cannot be driven here — `Transaction.updates` needs an `SKTestSession`, which
    /// `SubscriptionStoreKitTests` records is not always available — so, like `theListenerIsWired`,
    /// this pins the shape: the hand-over runs inside the drain's callback and runs **before** the
    /// counter bumps, so the screens the bump wakes find a server that has already been told. And
    /// `start(api:)` runs it once on its own, for the launch.
    @Test("the drain reconciles before it announces, and the listener's start reconciles once")
    func theDrainReconcilesFirst() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Rascal/Subscription/SubscriptionCenter.swift")
        let source = SubscriptionPriceTests.executableLines(of: try String(contentsOf: file, encoding: .utf8))

        let drain = try #require(source.range(of: "SubscriptionStore.drain(Transaction.updates)"))
        let inDrain = source[drain.upperBound...]
        let reconcile = try #require(inDrain.range(of: "await self?.reconcile()"))
        let refresh = try #require(inDrain.range(of: "await self?.refresh()"))
        let delivered = try #require(inDrain.range(of: "await self?.transactionDelivered()"))
        #expect(
            reconcile.lowerBound < refresh.lowerBound && refresh.lowerBound < delivered.lowerBound,
            "the drain must hand the receipt over before it re-reads and before it bumps the counter"
        )

        // Exactly one more `reconcile()` call in the file, for the launch — the one `start(api:)`
        // makes. Two would be a second launch path; none would be the defect back.
        let calls = source.components(separatedBy: "self?.reconcile()").count - 1
        #expect(calls == 2, "expected the drain's call and the launch's call, found \(calls)")

        // And `refresh()` is still the bare read it was. The foreground re-check must not have
        // grown a submission.
        if let body = source.range(of: "func refresh() async {") {
            let after = source[body.upperBound...]
            let end = after.range(of: "\n    }")?.lowerBound ?? after.endIndex
            #expect(!after[..<end].contains("reconcile"), "refresh() reconciles — a foreground now submits")
            #expect(!after[..<end].contains("householdRevision"), "refresh() bumps the new counter")
        }
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

// MARK: - The confirmation window, when the read is the slow part

/// **The reported symptom: "Finishing up" that never goes away.**
///
/// `EntitlementConfirmation.poll` bounds its sleeps and not its reads, so `purchase` can sit on
/// `.confirming` for as long as a household read takes to answer — around eleven minutes with
/// `URLSession`'s default request timeout, and forever if it never answers. Every other repair in
/// the model (`load()`'s reconcile, `refreshHousehold()`, `settleFailure`) is downstream of a poll
/// that has not returned, so none of them can reach it.
///
/// **These tests use a real clock deliberately.** The deadline under test is the one thing in this
/// model that must *not* be collapsed by the suite's stubbed `confirmationSleep` — that is the
/// whole reason it has a separate sleeper — so a fake clock here would assert nothing. The delays
/// are kept in the low hundreds of milliseconds so the cost is a fraction of a second.
@Suite("The confirmation window is bounded by more than its sleeps")
struct ConfirmationDeadlineTests {

    /// Polls `condition` on the main actor until it holds or the budget runs out.
    ///
    /// Deliberately **not** `withTaskGroup`: `load()`'s own comment records that a task group does
    /// not return until every child finishes and that `cancelAll()` only *requests*, so racing a
    /// deadline against a parked read inside one wedges the test rather than failing it. Observing
    /// published state from the outside has neither problem.
    @MainActor
    private func eventually(
        within budget: Duration = .milliseconds(3000),
        _ condition: () -> Bool
    ) async -> Bool {
        let step = Duration.milliseconds(25)
        var waited = Duration.zero
        while waited < budget {
            if condition() { return true }
            try? await Task.sleep(for: step)
            waited += step
        }
        return condition()
    }

    /// A model whose schedule is collapsed the way the rest of the suite collapses it, but whose
    /// **deadline is real and short** — the one clock a test of this must not fake.
    @MainActor
    private func model(
        deadline: Duration,
        store: any SubscriptionPurchasing,
        read: @escaping @Sendable () async throws -> FamilySummary
    ) -> SubscriptionModel {
        SubscriptionModel(
            readHousehold: read,
            store: store,
            confirmationSchedule: Array(repeating: .zero, count: 10),
            confirmationSleep: { _ in },
            confirmationDeadline: deadline,
            confirmationDeadlineSleep: { try await Task.sleep(for: $0) }
        )
    }

    @Test("A household read slower than the window must not leave the parent on \"Finishing up\"")
    @MainActor
    func aSlowReadStillMovesTheScreen() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()

        // `load()` needs one answering read to reach `.ready`; every read after it takes far longer
        // than the deadline. Finite rather than parked, so nothing outlives the test.
        let model = model(deadline: .milliseconds(200), store: store) {
            if await calls.bump() > 1 { try? await Task.sleep(for: .seconds(10)) }
            return await household("free", id: familyID)
        }

        await model.load()
        #expect(model.canBuy, "the harness has to reach a buyable state or this proves nothing")

        let buying = Task { await model.buy() }
        defer { buying.cancel() }

        let moved = await eventually { model.purchase == .late }
        #expect(
            moved,
            """
            purchase never left .confirming. The poll is suspended inside a household read, so the \
            sheet shows "Finishing up" for as long as that read takes — the schedule cannot end a \
            window that is parked in a read.
            """
        )
    }

    @Test("The deadline never fires on a confirmation that actually lands")
    @MainActor
    func aPromptConfirmationBeatsTheDeadline() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()
        // A deadline long enough that only a genuinely stuck window would reach it, against reads
        // that answer immediately — the ordinary purchase, which must be untouched by this change.
        //
        // **`free` on the first read and `subscribed` after**, because a household the server
        // already calls subscribed is not offered a purchase at all: `buy()` returns at its own
        // `guard canBuy` and `purchase` never leaves `.idle`. Answering `subscribed` to `load()`
        // tests that rule over again instead of testing this one.
        let model = model(deadline: .seconds(30), store: store) {
            let n = await calls.bump()
            return await household(n == 1 ? "free" : "subscribed", id: familyID)
        }

        await model.load()
        await model.buy()

        #expect(model.purchase == .subscribed)
        #expect(model.household?.isSubscribed == true)
    }

    @Test("A late confirmation that arrives after the deadline still wins")
    @MainActor
    func theServerGetsTheLastWord() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()

        // Free while the deadline runs, subscribed shortly after it fires. The parent must end on
        // "You're subscribed", not on the deadline's sentence — the server is the authority (D5)
        // and arriving late does not change that.
        let model = model(deadline: .milliseconds(150), store: store) {
            let n = await calls.bump()
            if n == 1 { return await household("free", id: familyID) }
            try? await Task.sleep(for: .milliseconds(300))
            return await household("subscribed", id: familyID)
        }

        await model.load()
        let buying = Task { await model.buy() }
        defer { buying.cancel() }

        // It passes through the deadline's answer first...
        _ = await eventually { model.purchase == .late }
        // ...and then the read lands and overrides it.
        let settled = await eventually { model.purchase == .subscribed }
        #expect(settled, "a subscribed household that arrives late must still be published")
    }
}

// MARK: - Phase 140: the receipt the app holds

private actor Submissions {
    private(set) var all: [String] = []
    func record(_ signed: String) { all.append(signed) }
}

/// What `APIClient.send` actually throws for a `409`: the documented envelope, decoded, with its
/// code. **Not `unexpectedStatus(409)`** — that is a 409 whose body was not the envelope, which
/// carries no code and is therefore not a verdict about anything; the tests that use it are
/// asserting exactly that. Phase 143.
private let conflict = APIError.api(
    code: .conflict,
    message: "This transaction belongs to a different household.",
    field: nil,
    status: 409
)

/// Holds a task so an injected read can wait for it to finish — the way a poll read is made to
/// observe another door's answer landing *between* two of its own reads, deterministically.
private actor TaskBox {
    private var task: Task<Void, Never>?
    func hold(_ task: Task<Void, Never>) { self.task = task }
    func wait() async { await task?.value }
}

/// **The evening of Sep 2, 2026, and the door it forced.** A Monthly tap on an Apple Account that
/// already held the annual is a plan change; Apple announces it as `DID_CHANGE_RENEWAL_PREF` (no
/// tier effect) and no amount of polling `GET /families/me` would ever have confirmed it — while
/// the device held, the whole time, an Apple-signed transaction proving the household was paid up.
/// `POST /v1/families/me/transactions` is how the app hands that over, and these tests pin what
/// the model does with the answer and, more importantly, what it does with every non-answer.
@Suite("Phase 140 — the app hands the server the transaction it holds")
struct SubmittedTransactionTests {

    @MainActor
    private func model(
        store: FakeStore,
        read: @escaping @Sendable () async throws -> FamilySummary,
        submit: @escaping @Sendable (String) async throws -> FamilySummary
    ) -> SubscriptionModel {
        SubscriptionModel(
            readHousehold: read,
            submitTransaction: submit,
            store: store,
            confirmationSchedule: Array(repeating: .zero, count: 10),
            confirmationSleep: { _ in }
        )
    }

    @Test("a purchase confirms on the submission, without a single poll read")
    @MainActor
    func submissionConfirmsWithoutPolling() async {
        let familyID = UUID()
        let reads = Counter()
        let submissions = Submissions()
        let store = FakeStore(entitlement: "jws.of.the.purchase")
        let model = model(
            store: store,
            read: {
                _ = await reads.bump()
                return await household("free", id: familyID)
            },
            submit: { signed in
                await submissions.record(signed)
                return await household("subscribed", id: familyID)
            }
        )

        await model.load()
        let readsAfterLoad = await reads.read()
        await model.buy()

        #expect(model.purchase == .subscribed)
        #expect(model.household?.isSubscribed == true)
        let submitted = await submissions.all
        #expect(submitted == ["jws.of.the.purchase"])
        let readsAfterBuy = await reads.read()
        #expect(
            readsAfterBuy == readsAfterLoad,
            "the poll ran although the submission had already answered with the household"
        )
        let asked = await store.entitlementReads
        #expect(asked == 1)
    }

    /// **The household the server answered with is the one kept**, not a second read: a re-read
    /// could fail and blank a household the app had just confirmed.
    @Test("the household in the answer is the one on screen")
    @MainActor
    func theAnsweredHouseholdIsKept() async {
        let familyID = UUID()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: { await household("free", id: familyID) },
            submit: { _ in
                var family = await household("subscribed", id: familyID)
                family = FamilySummary(
                    familyId: family.familyId, tier: family.tier, access: family.access,
                    lapsedAt: nil, plan: "monthly", billingRetry: nil, isPayer: true,
                    entitled: nil, entitlementSource: nil,
                    guardians: family.guardians, pendingInvites: []
                )
                return family
            }
        )

        await model.load()
        await model.buy()

        #expect(model.household?.plan == "monthly")
        #expect(model.household?.isPayer == true)
    }

    /// A `404` from a server without the route, a `409`, a `422`, a dropped connection: every one
    /// is a throw, and a throw is not a verdict. The poll runs exactly as it did before phase 140.
    @Test("a server that predates the route leaves the poll exactly as it was")
    @MainActor
    func aThrowFallsThroughToThePoll() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: {
                let n = await calls.bump()
                return await household(n >= 4 ? "subscribed" : "free", id: familyID)
            },
            submit: { _ in throw APIError.unexpectedStatus(404) }
        )

        await model.load()
        await model.buy()

        #expect(model.purchase == .subscribed, "the poll did not run after the submission threw")
        #expect(model.household?.isSubscribed == true)
    }

    /// A `200` whose household still reads `free` — an expired receipt, a Sandbox receipt
    /// Production has outranked — is an answer, and the answer is *not yet*. Nothing on the device
    /// may read anything else into it (D5).
    @Test("a submission the server answers with free is not a confirmation")
    @MainActor
    func aFreeAnswerIsNotAConfirmation() async {
        let familyID = UUID()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: { await household("free", id: familyID) },
            submit: { _ in await household("free", id: familyID) }
        )

        await model.load()
        await model.buy()

        #expect(model.purchase == .late)
        #expect(model.household?.isSubscribed == false)
        #expect(!model.canBuy, "a purchase that went through must not be offered again")
    }

    @Test("no transaction on the device means nothing is submitted, and the poll runs")
    @MainActor
    func nothingToSubmit() async {
        let familyID = UUID()
        let calls = Counter()
        let submissions = Submissions()
        let store = FakeStore(entitlement: nil)
        let model = model(
            store: store,
            read: {
                let n = await calls.bump()
                return await household(n >= 3 ? "subscribed" : "free", id: familyID)
            },
            submit: { signed in
                await submissions.record(signed)
                return await household("subscribed", id: familyID)
            }
        )

        await model.load()
        await model.buy()

        let submitted = await submissions.all
        #expect(submitted.isEmpty)
        #expect(model.purchase == .subscribed)
    }

    // MARK: Restore

    /// **What a restore actually restores now.** Before phase 140 it was `AppStore.sync()` and a
    /// re-read of a server that had never been told — "nothing has arrived yet", to a parent
    /// holding a paid-up receipt.
    @Test("a restore submits the receipt and reports found, without polling")
    @MainActor
    func aRestoreSubmits() async {
        let familyID = UUID()
        let reads = Counter()
        let submissions = Submissions()
        let store = FakeStore(entitlement: "jws.from.currentEntitlements")
        let model = model(
            store: store,
            read: {
                _ = await reads.bump()
                return await household("free", id: familyID)
            },
            submit: { signed in
                await submissions.record(signed)
                return await household("subscribed", id: familyID)
            }
        )

        await model.load()
        let readsAfterLoad = await reads.read()
        await model.restore()

        #expect(model.household?.isSubscribed == true)
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(model.notice == nil)
        let submitted = await submissions.all
        #expect(submitted == ["jws.from.currentEntitlements"])
        let readsAfterRestore = await reads.read()
        #expect(readsAfterRestore == readsAfterLoad)
        let restores = await store.restores
        #expect(restores == 1, "AppStore.sync() still runs first — it is what brings the receipt")
    }

    @Test("a restore whose submission is refused polls as before and says nothing arrived")
    @MainActor
    func aRefusedRestoreSubmissionPolls() async {
        let familyID = UUID()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: { await household("free", id: familyID) },
            submit: { _ in throw APIError.unexpectedStatus(409) }
        )

        await model.load()
        await model.restore()

        #expect(model.restoreConfirmation == nil)
        #expect(model.notice?.hasPrefix("Nothing has arrived yet") == true)
        #expect(model.household?.isSubscribed == false)
    }

    /// A restore that lands while a purchase is still `.confirming` or `.late` closes it — the
    /// same rule the poll's own `.subscribed` branch follows.
    @Test("a restore's answer settles an open purchase")
    @MainActor
    func aRestoreSettlesAnOpenPurchase() async {
        let familyID = UUID()
        let store = FakeStore(entitlement: "jws")
        let calls = Counter()
        let model = model(
            store: store,
            read: { await household("free", id: familyID) },
            submit: { _ in
                // Refused during the purchase, honoured on the restore.
                if await calls.bump() == 1 { throw APIError.unexpectedStatus(404) }
                return await household("subscribed", id: familyID)
            }
        )

        await model.load()
        await model.buy()
        #expect(model.purchase == .late)

        await model.restore()

        #expect(model.purchase == .subscribed)
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
    }

    // MARK: Phase 143: the receipt is another household's

    /// **Sep 3, 2026, in production.** A parent's Apple Account held a subscription bought under a
    /// household that was not the one they were signed in to — the account that bought it had since
    /// been deleted, or the same person had signed in with a different provider and been given a new
    /// household — so `POST /v1/families/me/transactions` answered `409 conflict`. The model read
    /// that as it read every other throw: carry on to the poll. Apple had said *"You're currently
    /// subscribed to this"*, the sheet said *"being confirmed"*, the window ran out, and nothing ever
    /// said why. A 409 is not a non-answer. It is the one refusal that names a reason the parent can
    /// act on, and it is the one this block makes visible.
    @Test("a receipt attached to another household ends the confirmation and says so")
    @MainActor
    func aConflictIsSaidNotSwallowed() async {
        let familyID = UUID()
        let reads = Counter()
        let store = FakeStore(entitlement: "jws.bought.under.another.account")
        let model = model(
            store: store,
            read: {
                _ = await reads.bump()
                return await household("free", id: familyID)
            },
            submit: { _ in throw conflict }
        )

        await model.load()
        let readsAfterLoad = await reads.read()
        await model.buy()

        #expect(model.purchase == .idle, "the spinner must not run to the deadline on an answer")
        #expect(model.notice == SubscriptionModel.subscriptionOnAnotherAccount)
        #expect(model.household?.isSubscribed == false, "no tier is claimed")
        let readsAfterBuy = await reads.read()
        #expect(
            readsAfterBuy == readsAfterLoad,
            "the poll ran although the server had already said whose receipt it is"
        )
        #expect(
            model.canBuy,
            "the sentence offers a purchase under a different Apple Account, so one must be possible"
        )
    }

    /// Every other throw is still what phase 140 made it: not a verdict. A `422` is a JWS Apple did
    /// not sign for this bundle, a transport failure is a dropped connection, and a `409` **without
    /// the envelope** carries no code — none of them says anything about whose receipt it is, so
    /// none of them may write a sentence.
    @Test("a 422, a transport failure and a body-less 409 are still not verdicts")
    @MainActor
    func otherThrowsStillFallThrough() async {
        let familyID = UUID()
        let refusals: [APIError] = [
            .api(
                code: .validationFailed, message: "not signed for this bundle",
                field: "signed_transaction", status: 422
            ),
            .transport("offline"),
            .unexpectedStatus(409),
        ]
        for refusal in refusals {
            let store = FakeStore(entitlement: "jws")
            let model = model(
                store: store,
                read: { await household("free", id: familyID) },
                submit: { _ in throw refusal }
            )

            await model.load()
            await model.buy()

            #expect(model.purchase == .late, "\(refusal) was treated as a verdict")
            #expect(model.notice == nil, "\(refusal) wrote a sentence it had no grounds for")
        }
    }

    /// The same refusal on the restore path. `aRefusedRestoreSubmissionPolls` above throws a 409
    /// with **no envelope**, which stays what it was; this is the envelope the server renders, and
    /// *"nothing has arrived yet"* would be the wrong sentence for it — something arrived, and the
    /// server said whose it is.
    @Test("a restore whose receipt is another household's says so, not that nothing arrived")
    @MainActor
    func aRestoreConflictIsSaid() async {
        let familyID = UUID()
        let reads = Counter()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: {
                _ = await reads.bump()
                return await household("free", id: familyID)
            },
            submit: { _ in throw conflict }
        )

        await model.load()
        let readsAfterLoad = await reads.read()
        await model.restore()

        #expect(!model.isRestoring)
        #expect(model.restoreConfirmation == nil)
        #expect(model.notice == SubscriptionModel.subscriptionOnAnotherAccount)
        #expect(model.household?.isSubscribed == false)
        let readsAfterRestore = await reads.read()
        #expect(readsAfterRestore == readsAfterLoad, "polling cannot change whose receipt it is")
        let dismisses = MembershipPresentation.dismissAfterRestore(
            household: model.household, notice: model.notice
        )
        #expect(!dismisses, "the paywall stays up so the sentence can be read")
    }

    /// A purchase whose window closed is `.late` — *"being confirmed"* — and a restore that then
    /// learns the receipt is another household's has answered that question too. Leaving `.late`
    /// standing would put *being confirmed* on the sheet above a sentence saying it will not be.
    @Test("a restore's 409 also closes a late purchase")
    @MainActor
    func aConflictClosesALatePurchase() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: { await household("free", id: familyID) },
            submit: { _ in
                // A server without the route during the purchase; the route, refusing, on restore.
                if await calls.bump() == 1 { throw APIError.unexpectedStatus(404) }
                throw conflict
            }
        )

        await model.load()
        await model.buy()
        #expect(model.purchase == .late)

        await model.restore()

        #expect(model.purchase == .idle)
        #expect(model.notice == SubscriptionModel.subscriptionOnAnotherAccount)
    }

    /// **The rule every writer in this model follows, facing this refusal.** A foreground read can
    /// publish a subscribed household while the submission is in flight — another guardian's
    /// purchase, a grant — and the 409 that then lands is about a receipt. The server has already
    /// said the household is a member by some other door, and a refused receipt does not take that
    /// back.
    @Test("a household the server calls subscribed outranks a refused receipt")
    @MainActor
    func aSubscribedHouseholdOutranksTheConflict() async {
        let familyID = UUID()
        let gate = Gate()
        let flipped = Counter()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: {
                let n = await flipped.read()
                return await household(n > 0 ? "subscribed" : "free", id: familyID)
            },
            submit: { _ in
                await gate.wait()
                throw conflict
            }
        )

        await model.load()
        let buying = Task { await model.buy() }
        await gate.readyToRelease()
        #expect(model.purchase == .confirming, "the harness has to park inside the submission")

        _ = await flipped.bump()
        await model.refreshHousehold()
        #expect(model.purchase == .subscribed)

        await gate.open()
        await buying.value

        #expect(model.purchase == .subscribed, "a refused receipt must not take back what the server granted")
        #expect(model.notice == nil)
    }

    /// `settleReceiptElsewhere()` guards the sentence on `isMember`, not `isSubscribed` — the
    /// distinction phase 141 exists for. A granted household reads `tier: free` with the card
    /// already saying *Subscribed*, and *attached to a different account* underneath would be the
    /// contradiction `aGrantedRestoreIsSilent` already refuses for *nothing has arrived yet*.
    @Test("a granted household is not told its receipt is somewhere else")
    @MainActor
    func aGrantedHouseholdIsSilentOnTheConflict() async {
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: { await grantedHousehold() },
            submit: { _ in throw conflict }
        )

        await model.load()
        await model.restore()

        #expect(model.notice == nil, "attached-to-another-account under a card reading Subscribed is the contradiction")
        #expect(model.restoreConfirmation == nil, "a grant is not a restored receipt")
    }

    /// **The sentence survives the visit that is meant to read it.** One `SubscriptionModel` is
    /// shared by Today and Settings (`RootView`), and a purchase from a locked card leaves the parent
    /// on the board when the sheet dismisses itself — so the sentence has to be there when they next
    /// open Settings, and `load()` runs from that card's `.task` on every appearance. Phase 141's rule
    /// that opening a surface clears `notice` was written for *nothing has arrived yet*, a statement
    /// about a past run; this is a statement about a standing fact, and it goes when the fact does.
    @Test("the other-account sentence survives opening a surface, and a membership takes it down")
    @MainActor
    func theConflictSentenceSurvivesALoad() async {
        let familyID = UUID()
        let flipped = Counter()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: {
                let n = await flipped.read()
                return await household(n > 0 ? "subscribed" : "free", id: familyID)
            },
            submit: { _ in throw conflict }
        )

        await model.load()
        await model.buy()
        #expect(model.notice == SubscriptionModel.subscriptionOnAnotherAccount)

        await model.load()
        #expect(
            model.notice == SubscriptionModel.subscriptionOnAnotherAccount,
            "the next visit to Settings is where this is read, and that visit is a load()"
        )

        _ = await flipped.bump()
        await model.refreshHousehold()
        #expect(model.notice == nil, "a member household outranks the sentence")
    }

    /// **The invariant `settleRestoreFound()` states, against the new writer.** A purchase's
    /// submission can still be in flight when the parent taps Restore. If the restore's own
    /// submission is inconclusive its poll runs; the purchase's 409 then lands *between two poll
    /// reads* and writes the sentence; the next read says subscribed. *Found it* beside *attached to
    /// a different account* is the contradiction, and the standing `notice` would also keep the
    /// paywall from dismissing on a restore that succeeded. Staged, not hoped for: the poll's first
    /// read releases the parked submission and waits for the purchase to finish before answering.
    @Test("a membership a restore finds takes the other-account sentence down with it")
    @MainActor
    func aFoundMembershipClearsTheConflictSentence() async {
        let familyID = UUID()
        let gate = Gate()
        let submissions = Counter()
        let reads = Counter()
        let purchase = TaskBox()
        let store = FakeStore(entitlement: "jws")
        let model = model(
            store: store,
            read: {
                let n = await reads.bump()
                // Read 1 is `load()`. Read 2 is the restore poll's first: it lets the purchase's
                // submission through and waits for its 409 to be written, then answers `free`.
                // Read 3 is the poll's second, and it says subscribed.
                if n == 2 {
                    await gate.open()
                    await purchase.wait()
                }
                return await household(n >= 3 ? "subscribed" : "free", id: familyID)
            },
            submit: { _ in
                if await submissions.bump() == 1 {
                    await gate.wait()
                    throw conflict
                }
                throw APIError.unexpectedStatus(404)
            }
        )

        await model.load()
        await purchase.hold(Task { await model.buy() })
        await gate.readyToRelease()
        #expect(model.purchase == .confirming, "the harness has to park inside the submission")

        await model.restore()

        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(model.notice == nil, "at most one of the two channels stands")
        #expect(model.household?.isSubscribed == true)
        let dismisses = MembershipPresentation.dismissAfterRestore(
            household: model.household, notice: model.notice
        )
        #expect(dismisses, "a restore that succeeded must be allowed to close the paywall")
    }

    // MARK: The failure the parent has read

    @Test("Not now on a refused purchase clears it, and only it")
    @MainActor
    func dismissFailureMovesOnlyFailed() async {
        let familyID = UUID()
        let store = FakeStore(outcomes: [.failure(.productsUnavailable)])
        let model = model(
            store: store,
            read: { await household("free", id: familyID) },
            submit: { _ in throw APIError.unexpectedStatus(404) }
        )

        await model.load()
        await model.buy()
        guard case .failed = model.purchase else {
            Issue.record("the harness has to reach .failed or this proves nothing")
            return
        }

        model.dismissFailure()

        #expect(model.purchase == .idle)
        #expect(model.canBuy, "a dismissed failure is not a spent purchase")

        // Every other state stays exactly where it is.
        let lateModel = self.model(
            store: FakeStore(entitlement: "jws"),
            read: { await household("free", id: familyID) },
            submit: { _ in await household("free", id: familyID) }
        )
        await lateModel.load()
        await lateModel.buy()
        #expect(lateModel.purchase == .late)
        lateModel.dismissFailure()
        #expect(lateModel.purchase == .late)
    }
}

// MARK: - Phase 141: a granted household is a member, not a buyer

/// **The card that contradicted itself.** A household the server entitles by an admin grant reads
/// `access: "subscribed"` with `tier: "free"` — deliberately, per the contract — and until phase
/// 141 the client read only `tier`: the status row said *Subscribed* while the row beneath it
/// offered to sell membership, and the paywall behind that row showed a live buy button for a
/// membership the household already had in full. `entitlement_source` is the field that tells
/// complimentary from paid, and these pin that it is read where the subject is selling, and
/// **not** read where the subject is an Apple receipt.
@Suite("Phase 141 — a granted household is a member, not a buyer")
struct GrantedHouseholdTests {

    @Test("entitled and entitlement_source decode, and their absence is nil rather than a failure")
    func theTwoFieldsDecodeAndTolerateAbsence() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let familyID = UUID()

        let granted = try decoder.decode(FamilySummary.self, from: Data("""
            {"family_id":"\(familyID.uuidString)","tier":"free","access":"subscribed",
             "entitled":true,"entitlement_source":"grant","guardians":[],"pending_invites":[]}
            """.utf8))
        #expect(granted.entitled == true)
        #expect(granted.entitlementSource == "grant")
        #expect(granted.isGranted)
        #expect(granted.isMember)
        #expect(!granted.isSubscribed, "a grant is not an Apple subscription")

        // A server predating phase 121 sends neither key. A non-optional here would have failed
        // this decode and taken the whole membership card with it.
        let older = try decoder.decode(FamilySummary.self, from: Data("""
            {"family_id":"\(familyID.uuidString)","tier":"subscribed","guardians":[],"pending_invites":[]}
            """.utf8))
        #expect(older.entitled == nil)
        #expect(older.entitlementSource == nil)
        #expect(!older.isGranted)
        #expect(older.isMember, "a receipt is still a membership without the newer fields")

        // A value a later server invents is carried, not crashed on, and is not a grant.
        let novel = try decoder.decode(FamilySummary.self, from: Data("""
            {"family_id":"\(familyID.uuidString)","tier":"free","access":"subscribed",
             "entitled":true,"entitlement_source":"sponsor","guardians":[],"pending_invites":[]}
            """.utf8))
        #expect(!novel.isGranted)
        #expect(!novel.isMember)
    }

    @Test("a trial is not a member — the paywall exists to be shown to one")
    @MainActor
    func aTrialIsStillOffered() {
        let trial = FamilySummary(
            familyId: UUID(), tier: "free", access: .trial, lapsedAt: nil, plan: nil,
            billingRetry: nil, isPayer: nil, entitled: true, entitlementSource: "trial",
            guardians: [], pendingInvites: []
        )
        #expect(!trial.isMember)
        #expect(MembershipPresentation.settingsAction(for: trial) == .offer)
    }

    @Test("the Settings card offers a granted household nothing — no upsell, no Manage")
    @MainActor
    func theCardSaysNothingToAGrantedHousehold() {
        let granted = grantedHousehold()
        #expect(
            MembershipPresentation.settingsHeader(for: granted).headline == MembershipCopy.Card.complimentary,
            "the header names what the household has, and it is not an Apple subscription"
        )
        #expect(
            MembershipPresentation.settingsAction(for: granted) == .hidden,
            "Subscribed with See-what-membership-includes beneath it is the contradiction"
        )
        // The receipt-keyed branch is untouched: a paying household is still managed.
        #expect(MembershipPresentation.settingsAction(for: household("subscribed")) == .manage)
        #expect(MembershipPresentation.settingsAction(for: household("free")) == .offer)
    }

    @Test("a granted household cannot be taken through a checkout")
    @MainActor
    func aGrantedHouseholdCannotBuy() async {
        let store = FakeStore()
        let model = makeModel(store: store) { await grantedHousehold() }

        await model.load()
        guard case .ready = model.phase else {
            Issue.record("the harness has to reach .ready or this proves nothing")
            return
        }

        #expect(!model.canBuy)
        await model.buy()
        let purchases = await store.purchases
        #expect(purchases.isEmpty, "buy() must return at its own guard, before StoreKit")
        #expect(model.purchase == .idle)
    }

    @Test("a grant landing mid-purchase does not hide the busy row")
    @MainActor
    func aGrantDoesNotHideFinishingUp() {
        let granted = grantedHousehold()
        #expect(
            MembershipPresentation.settingsAction(for: granted, purchase: .confirming)
                == .finishing(PurchaseCopy.finishingUp)
        )
        #expect(
            MembershipPresentation.settingsAction(for: granted, purchase: .purchasing)
                == .finishing(PurchaseCopy.talkingToAppStore)
        )
        // A grant landing while a purchase is late keeps the purchase's sentence, in the same
        // spirit as the two above (phase 144 moved `.late` into the card).
        #expect(
            MembershipPresentation.settingsAction(for: granted, purchase: .late)
                == .reported(PurchaseCopy.late)
        )
    }

    @Test("a granted household's fruitless restore says nothing under a card that reads Subscribed")
    @MainActor
    func aGrantedRestoreIsSilent() async {
        let store = FakeStore()
        let model = makeModel(store: store) { await grantedHousehold() }

        await model.load()
        await model.restore()

        #expect(model.restoreConfirmation == nil, "no receipt was restored")
        #expect(model.notice == nil, "nothing-has-arrived under Subscribed is the contradiction")
        #expect(
            MembershipPresentation.dismissAfterRestore(household: model.household, notice: model.notice),
            "the paywall's Done and this predicate key on the same thing"
        )
    }

    @Test("a receipt submission still means an Apple receipt, not a grant")
    @MainActor
    func theReceiptPathStillReadsTier() async {
        // `submitCurrentEntitlement` returns the household only if the server calls it
        // *subscribed* — a receipt question, which a grant must not answer. A granted household
        // handed back from the submit route is "carry on as before", exactly as a free one is.
        let familyID = UUID()
        let store = FakeStore(entitlement: "signed")
        let model = SubscriptionModel(
            readHousehold: { await household("free", id: familyID) },
            submitTransaction: { _ in await grantedHousehold(id: familyID) },
            store: store,
            confirmationSchedule: [],
            confirmationSleep: { _ in }
        )

        await model.load()
        await model.restore()

        #expect(model.restoreConfirmation == nil, "a grant is not a restored receipt")
    }
}

// MARK: - Phase 141: the restore window has a deadline too

/// **Phase 138's own sentence, one surface over.** `confirm()` was given a screen deadline on
/// Sep 1, 2026 and `restore()` was recorded as *"the identical unbounded read, deliberately left
/// alone"* — a minimal-fix rule, not a decision that the row may spin forever. App Review is
/// required to exercise restore, and a hung `AppStore.sync()` or household read parked
/// `isRestoring`, which spins the Settings row and disables both restore controls, with no
/// terminal state at all. These are `ConfirmationDeadlineTests` for the other window.
@Suite("Phase 141 — the restore window is bounded by more than its sleeps")
struct RestoreDeadlineTests {

    @MainActor
    private func eventually(
        within budget: Duration = .milliseconds(3000),
        _ condition: () -> Bool
    ) async -> Bool {
        let step = Duration.milliseconds(25)
        var waited = Duration.zero
        while waited < budget {
            if condition() { return true }
            try? await Task.sleep(for: step)
            waited += step
        }
        return condition()
    }

    /// The restore schedule is real (four reads) and the sleeps between them are collapsed, so a
    /// test waits on nothing but the read it controls and the deadline under test — which runs
    /// on the clock the suite does not collapse, for the reason `confirmationDeadlineSleep`
    /// documents.
    @MainActor
    private func model(
        deadline: Duration,
        store: any SubscriptionPurchasing,
        read: @escaping @Sendable () async throws -> FamilySummary
    ) -> SubscriptionModel {
        SubscriptionModel(
            readHousehold: read,
            store: store,
            confirmationSchedule: Array(repeating: .zero, count: 10),
            confirmationSleep: { _ in },
            confirmationDeadlineSleep: { try await Task.sleep(for: $0) },
            restoreDeadline: deadline
        )
    }

    @Test("a household read that never answers still releases the Settings row")
    @MainActor
    func aHungReadStillMovesTheRow() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()

        let model = model(deadline: .milliseconds(200), store: store) {
            if await calls.bump() > 1 { try? await Task.sleep(for: .seconds(10)) }
            return await household("free", id: familyID)
        }

        await model.load()
        let restoring = Task { await model.restore() }
        defer { restoring.cancel() }

        let started = await eventually { model.isRestoring }
        #expect(started, "the harness has to reach a spinning row or this proves nothing")

        let released = await eventually { !model.isRestoring }
        #expect(
            released,
            """
            isRestoring never went false. The restore is suspended inside a household read, so the \
            Settings row spins and both restore controls stay disabled for as long as that read \
            takes — the schedule cannot end a window that is parked in a read.
            """
        )
        #expect(model.notice == SubscriptionModel.restoreNothingYet)
        #expect(model.restoreConfirmation == nil)
    }

    @Test("the deadline never fires on a restore that actually answers")
    @MainActor
    func aPromptRestoreBeatsTheDeadline() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()
        let model = model(deadline: .seconds(30), store: store) {
            let n = await calls.bump()
            return await household(n == 1 ? "free" : "subscribed", id: familyID)
        }

        await model.load()
        await model.restore()

        #expect(!model.isRestoring)
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(model.notice == nil)
    }

    @Test("a membership found after the deadline still says so, and the deadline's sentence goes")
    @MainActor
    func theServerGetsTheLastWord() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()

        // Free on the load, then a read that answers *subscribed* only after the deadline has
        // released the row. The parent must end on "Found it", not on "nothing has arrived yet"
        // — the server is the authority (D5) and arriving late does not change that. And at most
        // one of the two sentences may stand, which is the invariant `restore()` states at its top.
        let model = model(deadline: .milliseconds(150), store: store) {
            let n = await calls.bump()
            if n == 1 { return await household("free", id: familyID) }
            try? await Task.sleep(for: .milliseconds(300))
            return await household("subscribed", id: familyID)
        }

        await model.load()
        let restoring = Task { await model.restore() }
        defer { restoring.cancel() }

        let released = await eventually { !model.isRestoring && model.notice != nil }
        #expect(released, "the deadline should speak first")

        let found = await eventually { model.restoreConfirmation == SubscriptionModel.restoreFound }
        #expect(found, "a membership that arrives late must still be published")
        #expect(model.notice == nil, "found and nothing-arrived cannot both stand")
        #expect(model.household?.isSubscribed == true)
    }

    @Test("a subscribed household whose restore times out gets a released row and silence")
    @MainActor
    func aSubscribedHouseholdIsNotToldNothingArrived() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()

        // Already subscribed when the parent taps — a non-payer guardian, say — and every read
        // after the load parks. The `.late` branch already refuses to write "nothing has arrived
        // yet" under a card that reads Subscribed; the deadline has to refuse the same way.
        let model = model(deadline: .milliseconds(150), store: store) {
            if await calls.bump() > 1 { try? await Task.sleep(for: .seconds(10)) }
            return await household("subscribed", id: familyID)
        }

        await model.load()
        let restoring = Task { await model.restore() }
        defer { restoring.cancel() }

        // Wait for the row to start spinning first, or `!isRestoring` is true before the task has
        // run at all and the test proves nothing.
        let started = await eventually { model.isRestoring }
        #expect(started, "the harness has to reach a spinning row or this proves nothing")

        let released = await eventually { !model.isRestoring }
        #expect(released)
        #expect(model.notice == nil, "nothing-has-arrived under Subscribed is the contradiction")
        #expect(model.restoreConfirmation == nil)
        #expect(model.household?.isSubscribed == true)
    }

    @Test("a run the deadline abandoned cannot speak for the run that replaced it")
    @MainActor
    func anAbandonedRunStaysQuiet() async {
        let familyID = UUID()
        let calls = Counter()
        // The first `AppStore.sync()` hangs past the deadline and then refuses; the second answers
        // at once. Before the generation guard, the first run's refusal landed as `notice` after
        // the second run had already found the membership — both sentences standing, and the
        // paywall's Done refusing to dismiss over an error the parent never caused.
        let store = LateRefusingStore(delay: .milliseconds(400))
        let model = model(deadline: .milliseconds(150), store: store) {
            let n = await calls.bump()
            return await household(n == 1 ? "free" : "subscribed", id: familyID)
        }

        await model.load()
        let first = Task { await model.restore() }
        defer { first.cancel() }
        let released = await eventually { !model.isRestoring && model.notice != nil }
        #expect(released, "the deadline releases the row with the not-found sentence")

        await model.restore()
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(model.notice == nil)

        // Let the abandoned run's refusal land.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(model.notice == nil, "the abandoned run's refusal is about a run nobody is watching")
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(!model.isRestoring)
    }

    @Test("an abandoned run returning while its replacement is in flight does not release the row")
    @MainActor
    func anAbandonedRunDoesNotReleaseItsReplacement() async {
        let familyID = UUID()
        let calls = Counter()
        let sleeps = Counter()
        // A refuses at 400 ms — after its 150 ms deadline has released the row and B has taken it.
        // B's poll read parks, so B is still in flight when A returns; B's own deadline is held
        // off (10 s) so nothing but A's return could release the row during the test.
        let store = LateRefusingStore(delay: .milliseconds(400))
        let model = SubscriptionModel(
            readHousehold: {
                if await calls.bump() > 1 { try? await Task.sleep(for: .seconds(10)) }
                return await household("free", id: familyID)
            },
            store: store,
            confirmationSchedule: Array(repeating: .zero, count: 10),
            confirmationSleep: { _ in },
            confirmationDeadlineSleep: { requested in
                try await Task.sleep(for: await sleeps.bump() == 1 ? requested : .seconds(10))
            },
            restoreDeadline: .milliseconds(150)
        )

        await model.load()
        let first = Task { await model.restore() }
        defer { first.cancel() }
        let released = await eventually { !model.isRestoring && model.notice != nil }
        #expect(released, "A's deadline releases the row")

        let second = Task { await model.restore() }
        defer { second.cancel() }
        let taken = await eventually { model.isRestoring && model.notice == nil }
        #expect(taken, "B has the row")

        // A's refusal lands while B is still parked in its read.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(model.isRestoring, "A's return must not release a row that is B's now")
        #expect(model.notice == nil, "A's refusal is about a run nobody is watching")
    }

    @Test("an abandoned run's deadline firing late cannot release its replacement either")
    @MainActor
    func anAbandonedDeadlineDoesNotReleaseItsReplacement() async {
        let familyID = UUID()
        let calls = Counter()
        let sleeps = Counter()
        let latch = Latch()
        // A refuses at 100 ms, before its deadline; its deadline task is cancelled at A's return
        // but is parked on the latch, so its body runs only when the test lets it — after B has
        // the row. Without the generation check, that body releases B's row and writes a
        // sentence under it.
        let store = LateRefusingStore(delay: .milliseconds(100))
        let model = SubscriptionModel(
            readHousehold: {
                if await calls.bump() > 1 { try? await Task.sleep(for: .seconds(10)) }
                return await household("free", id: familyID)
            },
            store: store,
            confirmationSchedule: Array(repeating: .zero, count: 10),
            confirmationSleep: { _ in },
            confirmationDeadlineSleep: { _ in
                if await sleeps.bump() == 1 { await latch.wait() } else { try await Task.sleep(for: .seconds(10)) }
            },
            restoreDeadline: .milliseconds(150)
        )

        await model.load()
        await model.restore()
        #expect(!model.isRestoring)
        #expect(model.notice != nil, "A's refusal is the current sentence")

        let second = Task { await model.restore() }
        defer { second.cancel() }
        let taken = await eventually { model.isRestoring && model.notice == nil }
        #expect(taken, "B has the row")

        await latch.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.isRestoring, "A's deadline must not release a row that is B's now")
        #expect(model.notice == nil, "A's deadline must not write under B")
    }

    @Test("a released row accepts a second tap, and the second run is a real one")
    @MainActor
    func aSecondTapAfterTheDeadlineRuns() async {
        let familyID = UUID()
        let calls = Counter()
        let store = FakeStore()

        // The first restore hangs forever; the deadline releases the row; the parent taps again
        // and this time the server answers. `guard !isRestoring` must not be the thing that
        // swallows the second tap — that guard was the whole wedge.
        let model = model(deadline: .milliseconds(150), store: store) {
            let n = await calls.bump()
            if n == 1 { return await household("free", id: familyID) }
            if n == 2 { try? await Task.sleep(for: .seconds(10)) }
            return await household("subscribed", id: familyID)
        }

        await model.load()
        let first = Task { await model.restore() }
        defer { first.cancel() }
        let released = await eventually { !model.isRestoring && model.notice != nil }
        #expect(released)

        await model.restore()

        let restores = await store.restores
        #expect(restores == 2, "the second tap reached the store")
        #expect(model.restoreConfirmation == SubscriptionModel.restoreFound)
        #expect(model.notice == nil)
    }
}

/// A store whose first `restore()` hangs for `delay` and then refuses, and whose later ones
/// succeed at once — the shape that lets an abandoned run return *after* its replacement.
private actor LateRefusingStore: SubscriptionPurchasing {
    private let delay: Duration
    private var restores = 0
    init(delay: Duration) { self.delay = delay }
    func loadOffer() async throws -> SubscriptionOffer { .double }
    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome { .cancelled }
    func restore() async throws {
        restores += 1
        if restores == 1 {
            try? await Task.sleep(for: delay)
            throw SubscriptionStoreError.unverified
        }
    }
    func currentEntitlement() async -> String? { nil }
}

/// A wait that ignores cancellation, so a cancelled deadline task can be held until the test
/// decides its body may run. `withCheckedContinuation` is not cancellation-aware, which is the
/// property this needs and `Task.sleep` lacks.
private actor Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

