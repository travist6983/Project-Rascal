import Foundation
import Testing

@testable import Rascal

/// Phase 110 — the five things App Review requires on a paywall, pinned.
///
/// **Every test in this file exists because its absence was proven, not suspected.** Phase 110
/// deleted each control in turn from a green tree and re-ran the whole suite:
///
/// | what was deleted | tests that failed, before this file |
/// |---|---|
/// | the restore control (`model.restore()` and its button) | **0** of 1108 |
/// | the plan row's `Text(plan.displayName)` | **0** of 1108 |
///
/// Both are requirements under Schedule 2 §3.8(b), which guideline 3.1.2(c) points at, and either
/// one missing is a rejection rather than a cosmetic regression. **A rejection that no test can
/// see is the worst shape a defect has in this repository**, because the feedback arrives from
/// Apple, days later, against a build somebody already submitted.
///
/// This is not hypothetical. Phase 108 restyled the plan row to the approved design's shape — and
/// the approved design's plan row is price-and-period only, with **no product title** on any of
/// artboards `2a`–`2d`, and **no restore control and no legal links** anywhere on the sheet. The
/// `displayName` was in fact dropped during that restyle and put back only because a reviewer
/// happened to ask about it. Nothing in the suite would have said a word.
///
/// **Why these are source assertions rather than behavioural ones.** The thing being pinned is
/// *"this control is on that screen"*, and there is no way to ask a SwiftUI `View` what it renders
/// without a UI test — which this project does not have and should not grow for this. The
/// precedent is `SubscriptionTests.noCurrencyLiterals`, which scans the same directory for the same
/// class of defect: something that renders perfectly and is still wrong.
///
/// **Their known weakness, stated rather than papered over.** A source assertion is pinned to a
/// spelling. Phase 37b's review caught exactly this failure mode — `theListenerIsWired` grepped for
/// two substrings that both survived the single edit that reintroduced the bug it guarded. So each
/// test here pins **the call that does the work**, not a label a designer might reword: `restore()`
/// rather than `"Restore a purchase"`, `plan.displayName` rather than any particular product name.
/// Renaming `SubscriptionModel.restore()` would fail these tests, which is a false positive worth
/// having; deleting the button that calls it fails them too, which is the point.
///
/// The behavioural half of requirements 2, 3 and 4 — that price, period and trial actually reach a
/// rendered string — is pinned properly, below, against `PlanCopy.priceLine`.
@Suite("Phase 110 — App Review requirements")
struct AppReviewRequirementsTests {

    // MARK: - Reading the sources

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RascalTests
            .deletingLastPathComponent()      // Rascal
            .appendingPathComponent("Rascal")
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: root, encoding: .utf8)
        #expect(!text.isEmpty, "\(relativePath) is empty — this test stopped looking at the real file")
        return text
    }

    /// A source scan must not be satisfied by the comment that explains it. Every test below strips
    /// comment lines first, so a file that merely *discusses* restoring does not pass for one that
    /// offers it — which is the difference between this and a naive `contains`.
    private func code(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
            .joined(separator: "\n")
    }

    /// Assert a call is present, **without putting the file in the failure message.**
    ///
    /// `#expect(source.contains(x))` evaluates its way down to the haystack and prints it, so a
    /// failure here would dump six hundred lines of `PaywallSheet.swift` into the log and bury the
    /// sentence that says what to do about it. Binding the `Bool` first makes the failure read
    /// `(present → false)` followed by the message. Found by break-testing these tests rather than
    /// by reading them.
    private func expect(
        _ needle: String,
        in haystack: String,
        _ message: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let present = haystack.contains(needle)
        #expect(present, "missing `\(needle)` — \(message())", sourceLocation: sourceLocation)
    }

    // MARK: - 5 · A restore control, on the paywall and in Settings

    /// **Break-tested.** Deleting the restore `Button` from `legalRow` failed 0 of 1108 tests
    /// before this existed, and fails this one now.
    ///
    /// Guideline 3.1.2(c) wants restore reachable from the purchase surface. It is also the only
    /// path a parent has after reinstalling, or on a second device, so its absence is a support
    /// burden long before it is a rejection.
    @Test("the paywall offers to restore a purchase")
    func theRestoreControlIsOnThePaywall() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")
        expect("model.restore()", in: sheet, """
            App Review requires a restore control on the paywall (Schedule 2 §3.8(b), guideline \
            3.1.2(c)), and the approved design does not draw one on any artboard — so this is the \
            only thing standing between a restyle and a rejection.
            """)
    }

    /// The second half of requirement 5. Settings is where a parent who has already dismissed the
    /// sheet goes looking, and `SubscriptionSection` is that surface.
    @Test("Settings offers to restore a purchase")
    func theRestoreControlIsInSettings() throws {
        let section = try code("Subscription/SubscriptionSection.swift")
        expect("restore()", in: section, """
            Requirement 5 is "a restore control, on the paywall AND in Settings" — both, not either.
            """)
    }

    // MARK: - 1 · The title of each plan, from the product's display name

    /// **Break-tested.** Replacing `Text(plan.displayName)` with `EmptyView()` failed 0 of 1108
    /// tests before this existed.
    ///
    /// This is the requirement the approved design most invites you to drop, because the artboard
    /// genuinely does not have it: `2a`, `2b` and `2d` all draw the plan row as `$59.99 a year`
    /// with no title. That is a mockup drawing content and stopping — **a Review requirement is not
    /// something a mockup can design away**, which is the whole of the phase brief's precedence
    /// rule 1.
    @Test("the plan row names the product it is selling")
    func thePlanRowNamesTheProduct() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")
        expect("plan.displayName", in: sheet, """
            Guideline 3.1.2 requires the subscription's NAME alongside its length and price. The \
            approved design's plan row has no title, so restyling to match it deletes this — which \
            is exactly what happened once already during phase 108, and was caught by a reviewer \
            rather than by a test.
            """)
    }

    // MARK: - 2, 3 and 4 · Length as text, price, and trial terms

    /// The behavioural half, and the one that is properly pinned rather than pinned to a spelling.
    ///
    /// `PlanCopy.priceLine` is the single string that carries three of the five requirements, so a
    /// regression in it is a regression in all three at once.
    @Test("the price line carries the price and the period as text")
    func thePriceLineCarriesPriceAndPeriod() {
        let annual = SubscriptionOffer.withoutTrial.annual
        let line = PlanCopy.priceLine(annual)

        #expect(line.contains(annual.displayPrice), "requirement 3: the price must be in the line")
        #expect(line.contains("a year"), "requirement 2: the length must be written as text")
        // The price must be StoreKit's own formatted string rather than anything this app built —
        // a line that agreed with `displayPrice` only in USD would pass a weaker check.
        #expect(line == "$59.99 a year")
    }

    @Test("the price line states the trial terms when the product carries one")
    func thePriceLineCarriesTrialTermsWhenOffered() {
        let annual = SubscriptionOffer.double.annual
        let line = PlanCopy.priceLine(annual)

        // Requirement 4. The button no longer says "Start the free trial" — the copy file fixes the
        // primary action at "Become a member" — so **the price line is now the only place the trial
        // is disclosed**, which makes this test the whole of requirement 4 rather than a duplicate
        // of something the label also says.
        #expect(line.contains("free"), "requirement 4: the trial must be disclosed")
        #expect(line == "2 weeks free, then $59.99 a year")
    }

    /// The other side of requirement 4, and the one that is normal rather than exceptional.
    ///
    /// **No introductory offer will exist in production.** The trial is server-granted
    /// (`entitlements.trial_ends_at`), and a parent reaches this sheet only *after* their fortnight
    /// has ended — so `isEligibleForIntroOffer` is false and there is no trial to state. A line
    /// that promised one anyway would be telling a parent about an offer Apple will not give them,
    /// which is its own rejection.
    @Test("the price line promises nothing when there is no introductory offer")
    func thePriceLinePromisesNoTrialWhenThereIsNone() {
        let line = PlanCopy.priceLine(SubscriptionOffer.withoutTrial.annual)

        #expect(!line.contains("free"))
        #expect(!line.lowercased().contains("trial"))
    }

    // MARK: - Terms of Use and Privacy Policy

    /// Not one of the five, but the same rejection, and the same failure shape: the approved design
    /// draws no legal links on any artboard, so a restyle deletes them silently.
    ///
    /// **This pins that the sheet asks for them.** It deliberately does *not* assert they render —
    /// they cannot today, and that is a launch blocker recorded in
    /// `docs/design/design-conformance-110.md` §7.4 rather than a thing this test can fix:
    /// `Config.xcconfig` defines neither `TERMS_URL` nor `PRIVACY_URL`, so both resolve to empty and
    /// `LegalLinks` correctly returns nil. The keys are present and correct in
    /// `Config.xcconfig.example`; copying those two lines across is the entire fix.
    @Test("the paywall asks for both legal links")
    func theSheetRendersBothLegalLinks() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")

        expect("LegalLinks.terms", in: sheet, "App Review requires a Terms of Use link.")
        expect("LegalLinks.privacy", in: sheet, "App Review requires a Privacy Policy link.")
    }

    /// The host guard is what makes a missing URL render as *absent* rather than as a dead link, and
    /// a dead link on a paywall is worse than no link — it is a reviewer tapping through to nothing.
    ///
    /// **Pinned by source rather than by behaviour, because the behaviour is unreachable.**
    /// `LegalLinks.url(_:)` is private and takes an Info.plist *key*, so it can only be exercised by
    /// changing the test bundle's own plist — which would assert something about the test bundle
    /// rather than about the app. The phase brief is explicit that this guard "must not be relaxed",
    /// so what is worth pinning is that it is still there.
    ///
    /// The specific trap it defends against is documented at the guard itself: an xcconfig value
    /// containing an unescaped `//` is truncated to `https:`, which `URL(string:)` accepts happily.
    /// Without the host check that ships as a link to nowhere instead of as no link at all.
    @Test("the legal-link guard still requires a host")
    func theHostGuardIsIntact() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")
        expect("url.host()", in: sheet, """
            A truncated xcconfig value like "https:" parses as a URL, so without this guard a build \
            with broken configuration renders a dead Terms link rather than none — a Review \
            rejection instead of a visible gap.
            """)
    }
}
