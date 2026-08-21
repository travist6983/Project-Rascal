import Foundation

/// A subscription period, lifted out of StoreKit so the wording and the arithmetic can be tested
/// without constructing a `Product` — which no test can do.
nonisolated struct SubscriptionPeriodValue: Sendable, Equatable {
    enum Unit: Sendable, Equatable {
        case day, week, month, year

        var singular: String {
            switch self {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            }
        }
    }

    let value: Int
    let unit: Unit

    /// "2 weeks", "1 month". The number is Apple's, never ours — D1 says fourteen days and the
    /// product in App Store Connect is what actually decides it.
    var phrase: String {
        value == 1 ? "1 \(unit.singular)" : "\(value) \(unit.singular)s"
    }

    /// How a price is cadenced on a plan row: "a year", "a month". `1` is dropped, because
    /// "$59.99 every 1 year" is not a sentence anybody writes.
    var cadence: String {
        value == 1 ? "a \(unit.singular)" : "every \(value) \(unit.singular)s"
    }
}

/// D1's "two months free", **computed rather than written down.**
///
/// Twelve times the monthly price against the annual price. The saving is an arithmetic
/// consequence of two numbers set in App Store Connect, so it stays correct when a price tier
/// changes and in every currency — which a literal `"Save $11.89"` would not, silently, because
/// the string renders perfectly wherever it is wrong.
nonisolated enum AnnualSaving {

    /// Nil when there is no saving to claim, which is a real state rather than a defect: a
    /// storefront whose annual tier is not cheaper than twelve monthlies should say nothing, not
    /// round its way to a claim that is untrue there.
    static func describe(
        annualPrice: Decimal,
        monthlyPrice: Decimal,
        format: Decimal.FormatStyle.Currency
    ) -> String? {
        guard monthlyPrice > 0 else { return nil }
        let twelveMonths = monthlyPrice * 12
        let saving = twelveMonths - annualPrice
        guard saving > 0 else { return nil }

        // Whole months free, where it lands cleanly. `$59.99` against `$5.99 × 12` is 1.98
        // months, which is the "two months free" D1 describes and is not exactly two — so the
        // tolerance is what makes the claim expressible without overstating it.
        let months = NSDecimalNumber(decimal: saving).doubleValue
            / NSDecimalNumber(decimal: monthlyPrice).doubleValue
        let whole = months.rounded()
        if whole >= 1, abs(months - whole) < 0.05, let word = monthsWord(Int(whole)) {
            return "\(word) free"
        }
        return "Save \(saving.formatted(format))"
    }

    static func describe(_ offer: SubscriptionOffer) -> String? {
        describe(
            annualPrice: offer.annual.price,
            monthlyPrice: offer.monthly.price,
            format: offer.annual.priceFormat
        )
    }

    /// Spelled out to about as far as a subscription could plausibly save, then it becomes money
    /// again. A numeral beside two prices reads as a third price.
    private static func monthsWord(_ count: Int) -> String? {
        switch count {
        case 1: "One month"
        case 2: "Two months"
        case 3: "Three months"
        case 4: "Four months"
        default: nil
        }
    }
}

/// How a plan's price, cadence and trial are read out on a row.
///
/// **Every part comes off the product.** A hardcoded "14-day free trial" is a defect rather than a
/// shortcut: it would keep saying so in a storefront where Apple never granted the introductory
/// offer, which is an untrue claim about money on a screen a parent is about to pay from.
nonisolated enum TrialRule {

    /// A trial is shown only when the product **configures** one *and* Apple would **grant** it.
    ///
    /// Introductory-offer eligibility is per subscription group per Apple Account and it is spent:
    /// a parent who trialled the monthly and cancelled gets no trial on the annual, because D5a
    /// puts both in one group. Showing the configured offer regardless would put "2 weeks free,
    /// then $59.99 a year" and a **Start the free trial** button in front of somebody who would be
    /// charged today — a false claim about money on the one screen where that is least forgivable.
    static func resolve(
        configured: SubscriptionPeriodValue?,
        eligible: Bool
    ) -> SubscriptionPeriodValue? {
        eligible ? configured : nil
    }
}

nonisolated enum PlanCopy {

    /// "2 weeks free, then $59.99 a year" — or just the price and cadence when there is no trial.
    static func priceLine(_ plan: OfferedPlan) -> String {
        var line = plan.displayPrice
        if let cadence = plan.period?.cadence { line += " \(cadence)" }
        if let trial = plan.trial { line = "\(trial.phrase) free, then \(line)" }
        return line
    }

    /// The primary action's label. It promises a trial only when the product carries one.
    static func buyLabel(_ plan: OfferedPlan?) -> String {
        guard let plan, plan.trial != nil else { return "Subscribe" }
        return "Start the free trial"
    }
}
