import Foundation
import StoreKit

/// The StoreKit boundary, and deliberately nothing more than that.
///
/// **D5 is the whole design: StoreKit is a receipt, not the entitlement.** A successful
/// `Product.purchase()` on this device is not the app learning that the household is subscribed.
/// It is the app learning that Apple will shortly tell the *server* something. The server is what
/// the app then asks — the same reason the device never decides what day it is.
///
/// So this type holds product metadata and purchase progress, and **it holds no tier, exposes no
/// `isSubscribed`, and answers no question about entitlement.** That question has exactly one
/// answer and it comes from `GET /v1/families/me`. A convenience boolean here would be a second
/// authority over a fact that is only allowed one, which is the bug D4 and D5 exist to prevent.
///
/// An `actor` for the same reason `APIClient` is one: it is a boundary onto something outside the
/// process, every method suspends, and nothing it owns should be reachable from the main thread
/// without going through it. **This is also the only file in the app that imports StoreKit for
/// products or purchases** — everything above it speaks `OfferedPlan`.
actor SubscriptionStore: SubscriptionPurchasing {

    /// What `loadOffer()` resolved, so `purchase` does not go back to the network for a product
    /// the parent is already looking at. Re-fetched if a purchase somehow arrives first.
    private var products: [String: Product] = [:]

    init() {}

    // MARK: Products

    /// Load both durations, or fail.
    ///
    /// **The empty result is the single most common StoreKit failure and it looks exactly like a
    /// network problem**, which is why it gets its own case rather than an empty array the caller
    /// might render as a paywall with nothing on it. `Product.products(for:)` returns the ids it
    /// could resolve and silently omits the rest — so an unknown identifier, a product not yet
    /// approved, and a device with no store account all arrive here as "fewer than two", never as
    /// a thrown error.
    func loadOffer() async throws -> SubscriptionOffer {
        let resolved = try await fetchProducts()
        guard
            let annual = resolved[SubscriptionProducts.annual],
            let monthly = resolved[SubscriptionProducts.monthly]
        else {
            throw SubscriptionStoreError.productsUnavailable
        }
        // **Whether Apple would actually grant the trial, not merely whether one is configured.**
        // Introductory-offer eligibility is per subscription group per Apple Account, and it is
        // spent: a parent who trialled the monthly and cancelled is not offered a trial on the
        // annual, because it is one group. Reading `introductoryOffer` alone would put
        // "2 weeks free, then $59.99 a year" and a **Start the free trial** button in front of
        // somebody who would be charged $59.99 today — a false claim about money on the one screen
        // where that is least forgivable.
        //
        // One check for both plans, because D5a puts both durations in one group.
        let eligibleForTrial: Bool
        if let group = annual.subscription?.subscriptionGroupID {
            eligibleForTrial = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: group)
        } else {
            // No subscription info at all is not a subscription. Claim nothing.
            eligibleForTrial = false
        }

        return SubscriptionOffer(
            annual: OfferedPlan(annual, plan: .annual, trialEligible: eligibleForTrial),
            monthly: OfferedPlan(monthly, plan: .monthly, trialEligible: eligibleForTrial)
        )
    }

    @discardableResult
    private func fetchProducts() async throws -> [String: Product] {
        let all: [Product]
        do {
            all = try await Product.products(for: SubscriptionProducts.all)
        } catch {
            throw SubscriptionStoreError.productsUnavailable
        }
        products = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return products
    }

    // MARK: Purchase

    /// Buy, carrying the household on the transaction.
    ///
    /// **`appAccountToken` must be the household's `family_id`, and this is the most important
    /// line in the phase.** `POST /v1/webhooks/app-store` has no other channel for learning whose
    /// household a transaction belongs to — Apple carries exactly one opaque UUID and this is it.
    /// A purchase made without it produces a receipt no server-side process can ever attribute,
    /// and that is unrecoverable: not a bug to fix in the next release, a support conversation per
    /// affected customer, forever.
    ///
    /// The `familyID` argument is non-optional on purpose. There is no substituting a fresh UUID
    /// and no purchasing without one — a caller that does not know the household cannot get here,
    /// and `SubscriptionModel` disables the button rather than inventing a token.
    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome {
        let product: Product
        if let known = products[plan.productID] {
            product = known
        } else if let fetched = try await fetchProducts()[plan.productID] {
            product = fetched
        } else {
            throw SubscriptionStoreError.productsUnavailable
        }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: [.appAccountToken(familyID)])
        } catch {
            throw Self.mapped(error)
        }

        switch result {
        case .success(let verification):
            switch verification {
            case .unverified:
                // **Deliberately not finished.** Finishing tells Apple to stop redelivering a
                // transaction, and this is one we could not verify and will not act on. Leaving
                // it unfinished means Apple offers it again, which is the recoverable shape.
                throw SubscriptionStoreError.unverified
            case .verified(let transaction):
                await transaction.finish()
                return .purchased
            }

        case .pending:
            // Ask to Buy, or a bank's SCA challenge. **This is not a failure** and must not be
            // rendered as one: the parent has done everything asked of them and somebody else has
            // to approve it. `Transaction.updates` is what delivers the approval, whenever it
            // comes, including on a later launch.
            return .pending

        case .userCancelled:
            return .cancelled

        @unknown default:
            // A result this build does not know about. Reported rather than guessed at — the two
            // guesses available are "succeeded" and "failed" and both can be wrong about money.
            throw SubscriptionStoreError.unknownResult
        }
    }

    // MARK: Restore

    /// `AppStore.sync()`, then the caller refreshes from the server.
    ///
    /// Apple requires a restore path for auto-renewables and Review rejects a build without one.
    /// It is genuinely rare here, and the UI says so rather than implying the parent is missing a
    /// step: the entitlement follows the **household**, not the device, so a new phone signed into
    /// the same account already works. This is for the case where it did not.
    func restore() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: The listener

    /// Drain a stream of transaction updates, finishing each verified one and then asking the
    /// **server** what it means.
    ///
    /// Started at launch and never cancelled — see `OnboardingGate`. It is the delivery path for
    /// renewals, refunds, Ask-to-Buy approvals, purchases made on another device, and any
    /// transaction Apple could not hand over during a session. Without it, a purchase completed
    /// while the app was backgrounded is never finished and Apple keeps redelivering it forever.
    ///
    /// **The body writes no tier and decides nothing.** `finish()`, then refresh from the server;
    /// per D5 that is the entire responsibility. An unverified update is skipped and left
    /// unfinished, for the same reason `purchase` refuses to finish one.
    ///
    /// Generic over the sequence so a test can attach it to `Transaction.updates` under an
    /// `SKTestSession` — the production call site passes exactly that.
    static func drain<Updates: AsyncSequence & Sendable>(
        _ updates: Updates,
        onVerified: @Sendable @escaping () async -> Void
    ) async where Updates.Element == VerificationResult<Transaction> {
        // `for try await` rather than `for await`: a generic `AsyncSequence` is not known to be
        // non-throwing in this language mode, and `Transaction.updates` — which never throws —
        // satisfies it either way. The `catch` is the stream ending, which is not a thing to tell
        // a parent about and not a thing to retry that a relaunch does not already do.
        do {
            for try await update in updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await onVerified()
            }
        } catch {}
    }

    // MARK: Errors

    private static func mapped(_ error: Error) -> SubscriptionStoreError {
        if let error = error as? SubscriptionStoreError { return error }

        // **`Product.purchase` throws two families and only one of them is `StoreKitError`.**
        // `Product.PurchaseError` carries the refusals a parent is most likely to actually meet —
        // purchases disabled by Screen Time, a product the storefront will not sell — and without
        // this branch every one of them reached a parent as `localizedDescription`.
        if let error = error as? Product.PurchaseError {
            switch error {
            case .purchaseNotAllowed:
                return .storeKit(
                    "Purchases are turned off for this device. You can change that in Settings, "
                        + "under Screen Time."
                )
            case .productUnavailable:
                return .storeKit("This subscription isn't available in your App Store region yet.")
            case .ineligibleForOffer, .invalidOfferIdentifier, .invalidOfferPrice,
                 .invalidOfferSignature, .missingOfferParameters:
                return .storeKit("That offer isn't available on this account.")
            // `.invalidQuantity` is a request this app malformed.
            // `.paymentMethodBindingConfigurationRequired` is iOS 26.5 and only reachable by an
            // app billing through an alternative payment provider, which this one is not — it is
            // listed rather than left to `@unknown default` because a case the SDK already
            // declares is not unknown, and the compiler warns until it is handled by name.
            // Neither is a thing a parent can act on, so they share the sentence.
            case .invalidQuantity, .paymentMethodBindingConfigurationRequired:
                return .storeKit("The App Store couldn't complete that. Nothing has been charged.")
            @unknown default:
                return .storeKit("The App Store couldn't complete that. Nothing has been charged.")
            }
        }

        guard let error = error as? StoreKitError else {
            return .storeKit(error.localizedDescription)
        }
        switch error {
        case .networkError:
            return .storeKit("The App Store couldn't be reached. Nothing has been charged.")
        case .userCancelled:
            // Reached only through `restore`; `purchase` maps cancellation to `.cancelled`
            // before it ever becomes an error.
            return .storeKit("That was cancelled. Nothing has been charged.")
        case .notAvailableInStorefront:
            return .storeKit("This subscription isn't available in your App Store region yet.")
        case .notEntitled:
            // `StoreKitError.notEntitled` is the *app* lacking entitlement to the request, which
            // is not the same as the device being restricted — that is
            // `Product.PurchaseError.purchaseNotAllowed`, handled above and worded for a parent.
            return .storeKit("The App Store refused that request.")
        default:
            // `.systemError`, `.unknown`, and anything Apple adds later. They differ in cause and
            // not in what a parent can do about it, so they share a sentence.
            return .storeKit("The App Store couldn't complete that. Nothing has been charged.")
        }
    }
}

// MARK: - Copying a product

nonisolated extension OfferedPlan {
    /// **The only production path into this type.** Every field is read off the product; nothing
    /// here is authored, defaulted or formatted by hand.
    init(_ product: Product, plan: SubscriptionPlan, trialEligible: Bool) {
        self.init(
            id: product.id,
            plan: plan,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            price: product.price,
            priceFormat: product.priceFormatStyle,
            period: SubscriptionPeriodValue(product.subscription?.subscriptionPeriod),
            trial: TrialRule.resolve(configured: Self.freeTrial(of: product), eligible: trialEligible)
        )
    }

    /// Nil unless the product genuinely carries a **free** introductory offer. A pay-up-front or
    /// pay-as-you-go intro is an introductory offer and is not a trial, and describing one as
    /// "free" on a screen a parent is about to pay from would be a false claim about money.
    ///
    /// Configured is not the same as granted — see `trialEligible` at the call site.
    private static func freeTrial(of product: Product) -> SubscriptionPeriodValue? {
        guard
            let intro = product.subscription?.introductoryOffer,
            intro.paymentMode == .freeTrial
        else { return nil }
        return SubscriptionPeriodValue(intro.period)
    }
}

nonisolated extension SubscriptionPeriodValue {
    init?(_ period: Product.SubscriptionPeriod?) {
        guard let period else { return nil }
        let unit: Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        self.init(value: period.value, unit: unit)
    }
}
