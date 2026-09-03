import Foundation

/// One duration, as everything above the StoreKit boundary needs it.
///
/// **A value rather than a `Product`, and that is the point.** `Product` cannot be constructed —
/// only StoreKit can make one — so a view layer typed on it can only be exercised by a working
/// `SKTestSession`, and a paywall that cannot be rendered without a store cannot be screenshotted,
/// previewed, or asserted against at accessibility sizes.
///
/// **Every field here is copied off a `Product` and none is authored.** There is no initialiser
/// that invents a price: `SubscriptionStore` fills these in from what the App Store returned, and
/// a test fills them in from what it wants to prove. The rule the phase actually cares about —
/// that no price, period or trial is ever written down in Swift — is unchanged, because the only
/// production path into this type is `init(_ product:)`.
nonisolated struct OfferedPlan: Sendable, Equatable {
    let id: String
    let plan: SubscriptionPlan
    /// The product's own display name, from App Store Connect.
    let displayName: String
    /// Formatted by StoreKit in the storefront's currency. Never assembled here.
    let displayPrice: String
    /// The raw amount, for the one comparison this app makes: twelve monthlies against an annual.
    let price: Decimal
    /// How that price is written, so a computed saving is formatted the same way as the prices it
    /// sits beside rather than in whatever the device locale happens to be.
    let priceFormat: Decimal.FormatStyle.Currency
    /// What the parent is charged for — a year, a month. Nil if the product is not a subscription.
    let period: SubscriptionPeriodValue?
    /// The free trial, and **only** when it is genuinely a free trial. A pay-up-front or
    /// pay-as-you-go introductory offer is not one and must not be described as one.
    let trial: SubscriptionPeriodValue?
}

/// Both durations, loaded. A value rather than an array, so "we have one of the two" is not a
/// state any caller has to handle — `loadOffer()` has already refused it.
nonisolated struct SubscriptionOffer: Sendable, Equatable {
    let annual: OfferedPlan
    let monthly: OfferedPlan

    func plan(for plan: SubscriptionPlan) -> OfferedPlan {
        switch plan {
        case .annual: annual
        case .monthly: monthly
        }
    }
}

/// What `purchase` came back with. **There is no `.subscribed` case**, because the type that
/// returns this is not allowed to know that — see `SubscriptionStore`.
nonisolated enum PurchaseOutcome: Sendable, Equatable {
    /// Verified and finished. The server does not know yet; the caller confirms.
    case purchased
    /// Waiting on somebody else. Not a failure.
    case pending
    /// They changed their mind. Silent — no error, no toast, no "are you sure?".
    case cancelled
}

/// The StoreKit boundary, as an interface.
///
/// **It exists so the purchase flow can be proven without a store.** `SKTestSession` is the
/// integration layer and it is not always available — see `SubscriptionStoreKitTests` — but the
/// behaviour that actually decides whether a parent is charged correctly is above this line, and
/// none of it should be untestable because Apple's harness is having a bad day.
nonisolated protocol SubscriptionPurchasing: Sendable {
    func loadOffer() async throws -> SubscriptionOffer
    /// **`familyID` is non-optional on purpose.** There is no substituting a fresh UUID and no
    /// purchasing without one; see `SubscriptionStore.purchase`.
    func purchase(_ plan: SubscriptionPlan, familyID: UUID) async throws -> PurchaseOutcome
    func restore() async throws
    /// The signed transaction this device holds for an active subscription in the group, if any
    /// — `Transaction.jwsRepresentation`, the thing `POST /v1/families/me/transactions` accepts.
    /// **Never an entitlement decision** (D5): it is a document the server verifies, and `nil`
    /// simply means there is nothing to hand over. See `SubscriptionStore.currentEntitlement`.
    func currentEntitlement() async -> String?
}

extension SubscriptionPurchasing {
    /// Nothing to hand over. **The real store overrides this**; the default exists for the test
    /// doubles that stand in for StoreKit and have no transaction to speak of, so a fake built
    /// for a hang or a refusal is not also obliged to invent a receipt.
    func currentEntitlement() async -> String? { nil }
}

nonisolated enum SubscriptionStoreError: Error, Equatable {
    /// Fewer than both products came back. Not the same as an error, and not a network problem
    /// however much it looks like one.
    case productsUnavailable
    /// The transaction failed Apple's signature check. Not finished, not acted on.
    case unverified
    /// A `PurchaseResult` case newer than this build.
    case unknownResult
    /// Anything the App Store itself refused, already turned into a sentence.
    ///
    /// **The message rather than the `StoreKitError`, because `StoreKitError` is not `Equatable`**
    /// and this type is — a test that asserts which refusal happened is worth more than keeping
    /// the original around for a `switch` nobody writes twice.
    case storeKit(String)

    /// What a parent reads. Plain, and it names what happened rather than a code.
    var userMessage: String {
        switch self {
        case .productsUnavailable:
            "The subscription options couldn't be loaded just now."
        case .unverified:
            // **It does not claim nothing was charged**, because the client cannot know that: a
            // transaction that fails Apple's signature check is one this app will not act on, not
            // one Apple did not process. Saying "nothing has been charged" and being wrong is the
            // worse error, so this says what is true and what happens next.
            "That purchase couldn't be verified, so it hasn't been applied. "
                + "If you were charged, it will appear once we can confirm it."
        case .unknownResult:
            "Something came back from the App Store that this version doesn't understand."
        case .storeKit(let message):
            message
        }
    }
}
