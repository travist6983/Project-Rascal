import Foundation
import Testing

@testable import Rascal

/// Phases 124, 125 and 126 — the three submission gaps, pinned.
///
/// **Same argument as `AppReviewRequirementsTests`, and the same known weakness.** The thing being
/// pinned is *"this control is on that screen"*, and there is no way to ask a SwiftUI `View` what
/// it renders without a UI test this project does not have. So these are source assertions, and
/// each one pins **the call that does the work** rather than a label somebody may reword.
///
/// **Every test here was seen red before it was seen green.** The four that could only ever have
/// been regression guards — because what they forbid was already absent — say so in their own doc
/// comment rather than being presented as evidence of this phase's change. That distinction is the
/// whole reason this file exists in the shape it does: phase 124's first draft of these tests had
/// four of six passing against the unmodified tree.
@Suite("Phases 124–126 — submission compliance")
struct SubmissionComplianceTests {

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

    /// Comment lines stripped, so a file that merely *discusses* a control does not pass for one
    /// that offers it. Copied deliberately from `AppReviewRequirementsTests` rather than shared:
    /// these two files pin the same class of thing and a helper either of them could quietly
    /// weaken is a helper that weakens both.
    private func code(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
            .joined(separator: "\n")
    }

    /// Every Swift file a parent can reach from the Settings screen, relative to `Rascal/`.
    ///
    /// Read off disk rather than listed, so a new file under `Settings/` is covered the day it is
    /// added. `SubscriptionSection` is the Membership card and is included explicitly: it renders
    /// inside Settings but lives under `Subscription/` beside the model it drives.
    private func settingsSurfaces() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rascal")
        let settings = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("Settings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { "Settings/" + $0.lastPathComponent }
        return (settings + ["Subscription/SubscriptionSection.swift"]).sorted()
    }

    /// Bind the `Bool` before asserting, so a failure prints the sentence rather than the file.
    private func expect(
        _ needle: String,
        in haystack: String,
        _ message: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let present = haystack.contains(needle)
        #expect(present, "missing `\(needle)` — \(message())", sourceLocation: sourceLocation)
    }

    private func expectAbsent(
        _ needle: String,
        in haystack: String,
        _ message: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let present = haystack.contains(needle)
        #expect(!present, "found `\(needle)` — \(message())", sourceLocation: sourceLocation)
    }

    // MARK: - 124 · The renewal disclosure

    /// **Seen red.** The sentence did not exist anywhere in `ios/` before this phase.
    ///
    /// Guideline 3.1.2 requires the renewal terms on the purchase screen itself, not one tap away
    /// behind Terms of Use. Pinned by value, because the requirement is about the words: it has to
    /// say that it renews and where to stop it.
    @Test("the renewal terms are the owner's sentence, verbatim")
    func theRenewalDisclosureIsTheOwnersSentence() {
        #expect(
            MembershipCopy.renewalTerms == "Membership renews automatically until cancelled. "
                + "Cancel any time in your Apple Account settings."
        )
    }

    /// **Seen red.** The half that matters: the string existing is not the string rendering.
    ///
    /// A constant nothing reads is not a disclosure. This pins the call site, so deleting the
    /// `renewalTerms` view from `content` fails here even though the copy file still compiles.
    @Test("the paywall renders the renewal terms")
    func theRenewalDisclosureIsOnThePaywall() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")
        expect("MembershipCopy.renewalTerms", in: sheet, """
            Guideline 3.1.2 wants the renewal terms on the paywall itself. A string in \
            MembershipCopy that no view reads is not on the paywall.
            """)
        expect("renewalTerms\nfootnote", in: sheet, """
            the disclosure has to be in `content`'s price group, above the action — a `private var` \
            nothing calls renders nowhere.
            """)
    }

    /// The disclosure goes through the same banned-phrase guard as every other string here, rather
    /// than being trusted because it is legal copy.
    @Test("the renewal terms are a statement, not a lever")
    func theRenewalDisclosureIsNotALever() {
        #expect(MembershipCopy.allUserVisibleStrings.contains(MembershipCopy.renewalTerms))
        #expect(!MembershipCopy.renewalTerms.contains("!"))
        #expect(!MembershipCopy.renewalTerms.contains("{"), "no pronoun token — this is not about a child")
    }

    // MARK: - 124 · The legal links open in the app

    /// **Seen red.** `SafariView.swift` did not exist; nothing in `ios/` imported `SafariServices`.
    @Test("there is one in-app browser wrapper, and it is first-party")
    func theSafariWrapperExists() throws {
        let wrapper = try source("DesignSystem/SafariView.swift")
        #expect(wrapper.contains("import SafariServices"))
        #expect(wrapper.contains("SFSafariViewController"))
        #expect(wrapper.contains("UIViewControllerRepresentable"))
    }

    /// **Seen red.** Both links were SwiftUI `Link`s, which hand the reader to Safari.
    ///
    /// For a reviewer checking guideline 3.1.2 that means leaving the app under review halfway
    /// through the check. This pins both halves — the `Link` gone, and the sheet that replaced it.
    @Test("the paywall's legal links open in the app, not in Safari")
    func thePaywallLegalLinksDoNotJumpOut() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")
        expectAbsent("Link(\"Terms of Use\", destination:", in: sheet, """
            a SwiftUI Link opens Safari and takes the reviewer out of the app mid-check.
            """)
        expectAbsent("Link(\"Privacy Policy\", destination:", in: sheet, """
            a SwiftUI Link opens Safari and takes the reviewer out of the app mid-check.
            """)
        // **The other way back to Safari, and the one a `Link`-shaped assertion misses.**
        // `@Environment(\.openURL)` hands the same page to the same other app without the word
        // `Link` appearing anywhere, so a guard that only forbids `Link(` leaves the whole suite
        // green on the one edit most likely to undo this change.
        expectAbsent("openURL", in: sheet, """
            an openURL call leaves the app exactly as a Link does, and reads as in-app in review.
            """)
        expect("SafariView(url: page.url)", in: sheet, "the sheet that replaced them")
        expect("legalLink(\"Terms of Use\"", in: sheet, "guideline 3.1.2 requires it on the paywall")
        expect("legalLink(\"Privacy Policy\"", in: sheet, "guideline 3.1.2 requires it on the paywall")
    }

    /// **Regression guard, not evidence of this phase.** `url.host()` was already there; the
    /// scheme check is new. Both are here because the property they defend is one property: a
    /// value this app cannot open renders as an *absent* link rather than a dead one.
    @Test("an unusable URL is still an absent link rather than a dead one")
    func theLinkGuardsAreIntact() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")
        expect("url.host()", in: sheet, "the xcconfig `//` trap truncates https:// to `https:`")
        expect("url.scheme ==", in: sheet, """
            SFSafariViewController opens http and https and nothing else; ftp:// has a host and \
            would survive the check above it.
            """)
        expect("if let terms = LegalLinks.terms", in: sheet, """
            the `if let` is what makes an unconfigured build render no control at all.
            """)
    }

    /// **The one test here that resolves a URL rather than reading source, and the gap it closes is
    /// the whole reason `blocked.md` §19 exists.**
    ///
    /// **Every other assertion in this file greps text off disk**, so all of them pass on a machine
    /// whose `Config.xcconfig` defines neither key — the paywall renders no links, Settings drops
    /// its About section entirely, the app looks perfectly fine, and the submission is rejected
    /// under guideline 3.1.2. §19 has been open since Aug 22, 2026 for exactly that, and its own
    /// note says the failure mode is *"a build that renders no links and looks perfectly fine"*.
    ///
    /// `LegalLinks` reads `Bundle.main`, which under `xcodebuild test` is the **test host** — the
    /// app — so this resolves the real values the real build was configured with. It therefore
    /// fails on a machine that has not copied the two keys across, which is the signal §19 wants.
    /// (`GoogleSignInTests` reads `Bundle.main` too, for the bundle display and product names — so
    /// the technique is not new here; what is new is applying it to the two keys §19 is about.)
    ///
    /// **CI is not weakened by this and is not the thing it protects.** `ios.yml` copies
    /// `Config.xcconfig.example`, which carries both keys with the `$()` split, so CI passes here
    /// for the right reason. What this catches is the developer machine and the machine that cuts
    /// the archive.
    @Test("the configured legal URLs actually resolve in this build")
    @MainActor
    func theLegalURLsResolveInThisBuild() throws {
        let terms = try #require(
            LegalLinks.terms,
            """
            TERMS_URL is missing or unusable in this build's Config.xcconfig. App Review requires             a Terms link on any screen selling a subscription; with this nil the paywall renders             none and nothing else notices. See blocked.md §19 — it carries the two lines to paste,             including the $() split that stops xcconfig reading // as a comment.
            """
        )
        let privacy = try #require(
            LegalLinks.privacy,
            """
            PRIVACY_URL is missing or unusable in this build's Config.xcconfig. Same consequence             and same fix as TERMS_URL above; see blocked.md §19.
            """
        )

        // **The truncation case, which is the one that ships as a *dead* link rather than none.**
        // `https://x/terms` written inline in xcconfig becomes `https:`, which `URL(string:)`
        // accepts. The host guard rejects it, so a truncated value arrives here as nil and is
        // caught by the `#require` above — but assert the host explicitly so a future guard that
        // stopped checking would fail here rather than silently.
        #expect(terms.host()?.isEmpty == false)
        #expect(privacy.host()?.isEmpty == false)
        #expect(terms.scheme == "https" || terms.scheme == "http")
        #expect(privacy.scheme == "https" || privacy.scheme == "http")
    }

    // MARK: - 124 · Dismiss on a successful restore

    /// **Seen red.** `dismissAfterRestore` did not exist, and the sheet stayed up after a restore
    /// that found a membership.
    ///
    /// **The device does not decide entitlement (D5).** Every input to this function came from the
    /// server: `household` is what `EntitlementConfirmation.poll` read back from
    /// `GET /v1/families/me`. Nothing here reads a receipt or consults StoreKit.
    @Test("only a restore that actually found a membership closes the paywall")
    func dismissOnlyOnAFoundMembership() throws {
        let subscribed = try Self.family(tier: "subscribed")
        let free = try Self.family(tier: "free")

        #expect(MembershipPresentation.dismissAfterRestore(household: subscribed, notice: nil))
        #expect(!MembershipPresentation.dismissAfterRestore(household: free, notice: nil))
        #expect(!MembershipPresentation.dismissAfterRestore(household: nil, notice: nil))
    }

    /// The case that makes the `notice` argument load-bearing rather than belt-and-braces: a
    /// household that was **already** subscribed when the parent tapped, and whose restore then
    /// failed. Dismissing there would close the sheet over an error they never got to read.
    @Test("a restore that failed does not close the paywall, even for a subscribed household")
    func aFailedRestoreDoesNotDismiss() throws {
        let subscribed = try Self.family(tier: "subscribed")

        #expect(
            !MembershipPresentation.dismissAfterRestore(
                household: subscribed, notice: "The App Store couldn't be reached."
            )
        )
    }

    /// **Seen red.** The pure function existing is not the paywall calling it — which is exactly
    /// the failure mode `AppReviewRequirementsTests`' own header warns about, and which phase
    /// 124's first draft of this suite had.
    @Test("the paywall acts on the dismiss decision")
    func thePaywallActsOnTheDismissDecision() throws {
        let sheet = try code("Subscription/PaywallSheet.swift")
        expect("MembershipPresentation.dismissAfterRestore(", in: sheet, """
            a restore that finds a membership has to close the sheet; a pure function nothing \
            calls closes nothing.
            """)
        expect("onDismiss()", in: sheet, "the decision has to reach the presentation")
    }

    /// **Regression guard.** Settings never dismissed; this pins that phase 126's confirmation did
    /// not quietly teach it to. The one difference between the two surfaces is the whole reason
    /// the decision lives in the caller rather than in `restore()`.
    @Test("Settings' restore does not dismiss anything")
    func settingsRestoreDoesNotDismiss() throws {
        let section = try code("Subscription/SubscriptionSection.swift")
        expectAbsent("dismissAfterRestore", in: section, """
            a restore from the Membership card must leave the parent on the card they were reading.
            """)
        expectAbsent("dismiss()", in: section, "same.")
    }

    // MARK: - 125 · The owner's eight strings

    /// **Seen red.** All four literals were the previous copy.
    ///
    /// Pinned by value because `free-tier-copy.md` forbids an agent authoring a string on this
    /// surface: editing one to read better fails here rather than shipping.
    @Test("the Membership card carries the owner's strings, verbatim")
    func theMembershipCardStringsAreTheOwners() throws {
        let section = try source("Subscription/SubscriptionSection.swift")
        #expect(section.contains("label: \"Your household\""))
        #expect(section.contains("label: \"See what membership includes\""))
        #expect(
            section.contains(
                "detail: \"One price covers everyone in the house — every parent, every child.\""
            )
        )
        #expect(
            section.contains("detail: \"If you've paid before and this phone doesn't know it yet.\"")
        )
    }

    /// **Seen red.** The footnote had no assertion of any kind before this — `grep -rn "One
    /// membership covers the whole family" ios/Rascal/RascalTests/` was empty — which is why a
    /// string the owner had already objected to on a neighbouring row survived on the paywall.
    ///
    /// Pinned by value, like the other owner-authored strings, so editing it to read better fails
    /// here rather than shipping.
    @Test("the paywall footnote is the owner's sentence and presumes no household shape")
    func thePaywallFootnoteIsTheOwners() {
        #expect(
            MembershipCopy.footnote
                == "One price covers everyone in the house — every parent, every child."
        )
        // The specific thing the owner objected to, on this string and on the Settings row it now
        // shares its wording with: a two-parent household is not the only shape there is.
        #expect(!MembershipCopy.footnote.contains("both parents"))
    }

    /// **Regression guard, and the one the brief asks for by name.** App Review 3.1.2(c) wants the
    /// restore control recognisable; renaming it is a rejection risk for no gain, so the title is
    /// the one string on this card the copy revision deliberately left alone.
    @Test("the restore row is still called Restore a purchase")
    func theRestoreTitleIsUnchanged() throws {
        let section = try source("Subscription/SubscriptionSection.swift")
        #expect(section.contains("label: \"Restore a purchase\""))
    }

    /// None of the eight replacements carries a pronoun token, and none of the strings they
    /// replaced did either — a replacement that silently dropped one would render `{They}` to a
    /// parent, or worse, guess a child's gender.
    @Test("no owner-authored membership string carries a pronoun token")
    @MainActor
    func noMembershipStringCarriesAToken() {
        let strings = [MembershipCopy.freeLabel] + MembershipCopy.stayFree
            + [SubscriptionModel.restoreFound]
        for string in strings {
            #expect(!string.contains("{"), "\(string) would render an unresolved token")
        }
    }

    // MARK: - 126 · The About section

    /// **Seen red.** Settings had no About section and no legal links at all — a parent who never
    /// opened the paywall had no way to read either page.
    @Test("Settings offers Terms and Privacy, in the app")
    func settingsOffersBothLegalPages() throws {
        let settings = try code("Settings/SettingsScreen.swift")
        expect("aboutSection", in: settings, "the section has to be rendered, not merely declared")
        expect("section(\"About\")", in: settings, "the section itself")
        expect("SettingsRow(label: \"Terms of Use\")", in: settings, "guideline 3.1.2")
        expect("SettingsRow(label: \"Privacy Policy\")", in: settings, "guideline 3.1.2")
        expect("LegalLinks.terms", in: settings, """
            one source of truth for the URLs — Config.xcconfig via Info.plist, per rule 5. A URL \
            written into Swift here would be a second one.
            """)
        expect("SafariView(url: url)", in: settings, "in the app, not handed to Safari")
    }

    /// The section is rendered from `content`, not merely declared. Deleting the one line that puts
    /// it on screen leaves `aboutSection` compiling and invisible.
    @Test("the About section is on the screen, not just in the file")
    func theAboutSectionIsRendered() throws {
        let settings = try code("Settings/SettingsScreen.swift")
        expect("appSection\naboutSection", in: settings, """
            declared-but-never-called is the exact shape of defect a source scan is here to catch.
            """)
    }

    /// **Seen red.** `restoreConfirmation` did not exist, so a restore from Settings spun and then
    /// stopped, which is indistinguishable from one that failed.
    @Test("a restore from Settings leaves a sentence behind")
    @MainActor
    func settingsSaysWhatARestoreFound() throws {
        let section = try code("Subscription/SubscriptionSection.swift")
        expect("model.restoreConfirmation", in: section, """
            Settings does not dismiss on success, so it is the surface that has to say what \
            happened.
            """)
        // **Pinned by value, like every other owner-authored string on this surface.** It was the
        // only one without one, which is how a string an agent placeheld could have survived a
        // later edit back into the tree unnoticed.
        #expect(SubscriptionModel.restoreFound == "Found it. Your membership is active.")
        #expect(!SubscriptionModel.restoreFound.contains("!"))
    }

    /// **Regression guard, and it is the brief's own break-test 3.** The phase 126 brief asked for
    /// a third Settings row calling `restore()`; the tree already had one under *Membership*, so
    /// building it would have put two controls invoking the identical method on one screen. This
    /// pins that there is exactly one — in either direction.
    @Test("there is exactly one restore control in Settings")
    func thereIsOneRestoreControlInSettings() throws {
        // **Enumerated from disk, not from a hardcoded pair.** A two-path list would pass while a
        // third file quietly grew its own restore control, which is the whole defect this pins.
        // Every Settings surface is every file under `Settings/`, plus `SubscriptionSection`,
        // which is the Membership card and lives under `Subscription/` for historical reasons.
        var surfaces = try settingsSurfaces()
        #expect(surfaces.count > 5, "the sweep stopped finding Settings sources")

        surfaces = try surfaces.filter { try code($0).contains(".restore()") }

        #expect(
            surfaces == ["Subscription/SubscriptionSection.swift"],
            """
            Guideline 3.1.2(c) asks that restore be reachable, not that it be reachable twice. \
            Found: \(surfaces)
            """
        )
    }

    /// **Regression guard.** Nothing in Settings jumped out to Safari before, and nothing may now.
    @Test("no Settings row hands the reader to another app")
    func settingsDoesNotJumpOut() throws {
        let settings = try code("Settings/SettingsScreen.swift")
        expectAbsent("openURL", in: settings, "a legal page opens in the app, per the About section")
        expectAbsent("Link(\"Terms", in: settings, "same")
        expectAbsent("Link(\"Privacy", in: settings, "same")
    }

    // MARK: - Fixtures

    /// A household, decoded the way the app decodes one, so `isSubscribed` is the server's word on
    /// it rather than a Bool a test set by hand.
    private static func family(tier: String) throws -> FamilySummary {
        let json = """
            {
              "family_id": "33333333-3333-3333-3333-333333333333",
              "tier": "\(tier)",
              "guardians": [],
              "pending_invites": []
            }
            """
        return try APIClient.decoder.decode(FamilySummary.self, from: Data(json.utf8))
    }
}
