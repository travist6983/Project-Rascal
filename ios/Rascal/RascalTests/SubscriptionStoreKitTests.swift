import Foundation
import StoreKit
import StoreKitTest
import Testing

@testable import Rascal

/// The integration layer: the one hop `SubscriptionPurchaseTests` cannot see past — whether
/// `SubscriptionStore` actually hands `appAccountToken` to `Product.purchase(options:)`, and
/// whether a transaction is finished, delivered and restored the way Apple says.
///
/// # This suite is disabled, and the reason is not a shortcut
///
/// **`SKTestSession` cannot install a configuration on this machine.** Every call, on every
/// configuration shape, logs:
///
/// ```
/// [SKTestSession] Error saving configuration file: Error Domain=SKInternalErrorDomain Code=3
/// [SKTestSession] Error setting value to 1 for identifier 2 for com.travisterry.childarchive
/// ```
///
/// and `Product.products(for:)` then resolves **zero** products, with no thrown error — which is
/// indistinguishable from the wrong-identifier case this phase is careful about elsewhere.
///
/// What was ruled out, each by running it rather than by reasoning about it, on Aug 20, 2026 with
/// Xcode 26.4.1 (17E202):
///
/// * **The configuration's schema.** Six variants were tried, including one stripped to a single
///   subscription with no introductory offer, no settings block and no localizations. All six
///   failed identically, which is what says the file is not the problem.
/// * **Code signing.** `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=YES` with the team,
///   both identical. (Worth ruling out: an unsigned simulator build loses keychain access here,
///   which has bitten this project before.)
/// * **The scheme's `StoreKitConfigurationFileReference`.** Present and absent, identical —
///   `TestAction` inherits `LaunchAction`'s environment, so a scheme-installed configuration
///   colliding with a programmatic one was a real hypothesis. It is not the cause.
/// * **The runtime.** iOS 26.3 and a freshly created iOS 26.4 device, identical.
/// * **The device.** Erased, and a brand-new one, identical.
/// * **The daemon.** `storekitd` is running in the booted simulator, and
///   `StoreKitTest.framework` is present in the runtime root.
///
/// So the failure is below this file and outside this phase's diff. **Nothing here is known to be
/// wrong; it is unrun**, which is a different and weaker claim, and the PR says so in those words.
/// `Vellum.storekit` is committed exactly so this suite becomes runnable the moment the
/// environment does — remove the `.disabled` trait and nothing else needs to change.
///
/// **Even fully green, this suite would not prove the thing the phase actually rests on.** No
/// product exists in App Store Connect (`docs/blocked.md` §10), so the `appAccountToken` round
/// trip to 37a's webhook has never been observed end to end and cannot be from here.
@Suite(
    "The subscription — against the StoreKit configuration",
    .serialized,
    .disabled("SKTestSession cannot install a configuration on this machine: SKInternalErrorDomain Code=3 on every configuration shape, signing mode, runtime and device. See the doc comment above.")
)
struct SubscriptionStoreKitTests {

    private func makeSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "Vellum")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        return session
    }

    @Test("both products load, and the identifiers are the permanent ones from D5a")
    func bothProductsLoad() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let offer = try await SubscriptionStore().loadOffer()
        #expect(offer.annual.id == "com.travisterry.childarchive.subscription.annual")
        #expect(offer.monthly.id == "com.travisterry.childarchive.subscription.monthly")
        #expect(!offer.annual.displayPrice.isEmpty)
        #expect(!offer.monthly.displayPrice.isEmpty)
    }

    @Test("the trial is read off the product rather than asserted")
    func theTrialComesFromTheProduct() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let offer = try await SubscriptionStore().loadOffer()
        // Whatever App Store Connect was configured with is what the screen says. The committed
        // configuration carries D1's fourteen days as Apple's nearest option, two weeks.
        #expect(offer.annual.trial == SubscriptionPeriodValue(value: 2, unit: .week))
    }

    @Test("Family Sharing is off, per D4 — a second opinion about who is entitled")
    func familySharingIsOff() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let products = try await Product.products(for: SubscriptionProducts.all)
        #expect(products.count == 2)
        for product in products {
            #expect(product.isFamilyShareable == false)
        }
    }

    @Test("a purchase carries the family id all the way onto the transaction")
    func thePurchaseCarriesTheFamilyID() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let familyID = UUID()
        let store = SubscriptionStore()
        _ = try await store.loadOffer()

        #expect(try await store.purchase(.annual, familyID: familyID) == .purchased)

        // **The hop the fake cannot see.** `POST /v1/webhooks/app-store` has no other channel for
        // learning whose household this is.
        var seen: UUID?
        for await result in Transaction.all {
            guard case .verified(let transaction) = result else { continue }
            seen = transaction.appAccountToken
        }
        #expect(seen == familyID)
    }

    @Test("a verified purchase is finished, so Apple stops redelivering it")
    func aVerifiedPurchaseIsFinished() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let store = SubscriptionStore()
        _ = try await store.loadOffer()
        _ = try await store.purchase(.annual, familyID: UUID())

        var unfinished = 0
        for await _ in Transaction.unfinished { unfinished += 1 }
        #expect(unfinished == 0)
    }

    @Test("Ask to Buy pends, and the approval arrives on Transaction.updates")
    func askToBuyPendsThenArrives() async throws {
        let session = try makeSession()
        session.askToBuyEnabled = true
        defer {
            session.askToBuyEnabled = false
            session.clearTransactions()
        }

        let store = SubscriptionStore()
        _ = try await store.loadOffer()

        // The listener is started before the purchase, exactly as `OnboardingGate` does.
        let arrivals = Arrivals()
        let listener = Task {
            await SubscriptionStore.drain(Transaction.updates) { await arrivals.bump() }
        }
        defer { listener.cancel() }

        #expect(try await store.purchase(.annual, familyID: UUID()) == .pending)

        // The only transaction in flight is the one awaiting approval. Matched by being the only
        // one rather than by `SKTestTransaction.state == .deferred`, which is deprecated.
        let pending = session.allTransactions()
        try session.approveAskToBuyTransaction(identifier: try #require(pending.first).identifier)

        #expect(await arrivals.waitForOne(), "an approved Ask to Buy never reached the listener")
    }

    @Test("a purchase made elsewhere is delivered to the listener and finished exactly once")
    func anInterruptedPurchaseIsFinishedOnce() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let arrivals = Arrivals()
        let listener = Task {
            await SubscriptionStore.drain(Transaction.updates) { await arrivals.bump() }
        }
        defer { listener.cancel() }

        // Bought outside the app — another device, or a purchase that completed while this one
        // was backgrounded. This is the transaction Apple redelivers forever if nothing finishes it.
        try await session.buyProduct(identifier: SubscriptionProducts.monthly)

        #expect(await arrivals.waitForOne())
        #expect(await arrivals.read() == 1, "the out-of-app purchase was delivered more than once")

        var unfinished = 0
        for await _ in Transaction.unfinished { unfinished += 1 }
        #expect(unfinished == 0, "an out-of-app purchase was left unfinished")
    }

    @Test("restore syncs without deciding anything about entitlement")
    func restoreSyncs() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        // The assertion is that it does not throw. What it *means* is the server's to say, and
        // `SubscriptionRestoreTests` covers that half.
        try await SubscriptionStore().restore()
    }
}

/// Counts callbacks from the drain, and waits for the first without a fixed sleep.
private actor Arrivals {
    private var count = 0
    func bump() { count += 1 }
    func read() -> Int { count }

    func waitForOne(within timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if count > 0 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return count > 0
    }
}
