import Foundation

/// The product identifiers, in **one place**, because App Store product identifiers cannot be
/// renamed after creation and a second copy at a call site is a second thing to get wrong.
///
/// D5a in `docs/decisions.md` chose these at a desk rather than mid-phase, and
/// `docs/blocked.md` §10 step 3 records the one that was nearly permanent: the subscription
/// group name is fixed on first save, and it was still `Dogear Membership` until Aug 17, 2026.
///
/// **No price, period or trial length appears here or anywhere else in Swift.** $5.99 and $59.99
/// are in `decisions.md` and they belong in App Store Connect. Every figure a parent reads comes
/// from `Product.displayPrice` and `Product.subscription`, because a literal is wrong in every
/// other currency, wrong the day a price tier changes, and wrong in a way no test catches — the
/// string renders perfectly.
nonisolated enum SubscriptionProducts {

    /// One group holding both durations, so StoreKit treats monthly → annual as a **plan change**
    /// rather than two live subscriptions.
    ///
    /// Not read by any code — StoreKit addresses products, not groups. It is here so the name
    /// this app was built against is written down somewhere the client can be checked against.
    ///
    /// **VERIFIED against App Store Connect, twice, and it is neither name this constant has
    /// held.** Corrected Sep 7, 2026.
    ///
    /// The earlier version of this comment posed the question honestly and got the options wrong.
    /// It said only the owner could look, and that the answer was either *"the group was never
    /// created"* or *"it exists as `Vellum Membership`"*. Someone had already looked, twice, and
    /// the answer was a third thing: the group is called **`Membership`**, with no product name in
    /// it at all. Phase 133's live submission session found it on Aug 29, 2026 and corrected D5a
    /// in the same sitting — *"the group actually created in App Store Connect is shorter still:
    /// `Membership`, with no product-name reference at all… Confirmed no lingering `Vellum`
    /// reference anywhere in the group or its products."* `docs/reports/asc-verification-2026-09-05.md`
    /// row 4a then re-checked it against the console with a screenshot: expected `Membership`,
    /// observed `Membership`, group ID 22332670, two subscriptions, **PASS**.
    ///
    /// So the group name was never permanent-on-first-save in the way D5a assumed — it changed
    /// again before creation — and the value here had drifted for eleven days while two written
    /// verifications said otherwise. That is the failure this constant exists to prevent, so the
    /// fix is the value, not the caveat.
    ///
    /// Not read by any code — StoreKit addresses products, not groups — which is exactly why it
    /// could be wrong this long. `RascalTests/PocketChronicle.storekit` carried the same wrong
    /// name and was corrected with it. The product identifiers below, which are the part that is
    /// genuinely permanent, never moved.
    static let groupName = "Membership"

    static let annual = "com.travisterry.childarchive.subscription.annual"
    static let monthly = "com.travisterry.childarchive.subscription.monthly"

    /// What `Product.products(for:)` is asked for. Order is not significant — StoreKit answers
    /// in its own, and an absent identifier is simply missing from the result rather than an
    /// error, which is why `SubscriptionStore.loadOffer()` matches by id instead of by position.
    static let all = [annual, monthly]
}

/// Which duration the parent is looking at. Annual is preselected, per D1.
nonisolated enum SubscriptionPlan: String, CaseIterable, Sendable, Equatable {
    case annual
    case monthly

    var productID: String {
        switch self {
        case .annual: SubscriptionProducts.annual
        case .monthly: SubscriptionProducts.monthly
        }
    }
}
