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
    static let groupName = "Pocket Chronicle Membership"

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
