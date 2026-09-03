import Foundation
import Testing

@testable import Rascal

/// **Phase 140 — the purchase leaves the sheet and is reported on the Membership card.**
///
/// Every decision this phase adds to the views is a pure function in `MembershipPresentation`,
/// because there is no view host in this target and a `.onChange` that does nothing passes every
/// test that does not look at it. What is asserted here is the *table*; the wiring is verified on
/// the simulator, with the console showing the sheet dismiss at `.confirming`.
@Suite("Phase 140 — a purchase reported on the card")
struct PurchaseReportingTests {

    // MARK: - When the sheet leaves

    /// The whole transition table. Only the *entry* into `.confirming` dismisses: the purchase
    /// has left the parent's hands and there is nothing further to ask of them.
    @Test(
        "the sheet dismisses on the entry into .confirming and on nothing else",
        arguments: [
            (SubscriptionModel.PurchasePhase.purchasing, SubscriptionModel.PurchasePhase.confirming, true),
            (.awaitingApproval, .confirming, true),
            (.idle, .confirming, true),
            (.purchasing, .failed("no"), false),
            (.purchasing, .awaitingApproval, false),
            (.purchasing, .idle, false),
            (.confirming, .late, false),
            (.confirming, .subscribed, false),
            (.confirming, .confirming, false),
            (.late, .subscribed, false),
            (.idle, .purchasing, false),
        ]
    )
    func dismissalTable(
        old: SubscriptionModel.PurchasePhase,
        new: SubscriptionModel.PurchasePhase,
        dismisses: Bool
    ) {
        #expect(MembershipPresentation.dismissAfterPurchase(from: old, to: new) == dismisses)
    }

    // MARK: - What the card shows in the offer row's slot

    @Test("a purchase in flight replaces the offer row with the busy row, in the sheet's words")
    func finishingReplacesTheOffer() {
        let free = household(tier: "free")
        #expect(
            MembershipPresentation.settingsAction(for: free, purchase: .confirming)
                == .finishing(PurchaseCopy.finishingUp)
        )
        #expect(
            MembershipPresentation.settingsAction(for: free, purchase: .purchasing)
                == .finishing(PurchaseCopy.talkingToAppStore)
        )
        // No household yet is still a purchase in flight — `buy()` cannot start without one, but
        // a foreground read can fail and blank it while the confirmation runs.
        #expect(
            MembershipPresentation.settingsAction(for: nil, purchase: .confirming)
                == .finishing(PurchaseCopy.finishingUp)
        )
    }

    @Test("the terminal states keep the offer row, because the sheet behind it says more")
    func terminalStatesKeepTheOffer() {
        let free = household(tier: "free")
        #expect(MembershipPresentation.settingsAction(for: free, purchase: .late) == .offer)
        #expect(MembershipPresentation.settingsAction(for: free, purchase: .awaitingApproval) == .offer)
        #expect(MembershipPresentation.settingsAction(for: free, purchase: .failed("no")) == .offer)
        #expect(MembershipPresentation.settingsAction(for: free, purchase: .idle) == .offer)
    }

    /// **The server wins.** A household it calls subscribed is managed whatever the local purchase
    /// machinery says — a confirmation racing a foreground read must not hide Manage from a member.
    @Test("a subscribed household is managed regardless of the purchase phase")
    func serverWinsOverThePurchasePhase() {
        let subscribed = household(tier: "subscribed")
        #expect(MembershipPresentation.settingsAction(for: subscribed, purchase: .confirming) == .manage)
        #expect(MembershipPresentation.settingsAction(for: subscribed, purchase: .late) == .manage)
        let notPayer = household(tier: "subscribed", isPayer: false)
        #expect(MembershipPresentation.settingsAction(for: notPayer, purchase: .confirming) == .hidden)
    }

    @Test("the default purchase phase is idle, so every existing caller reads as before")
    func defaultIsIdle() {
        let free = household(tier: "free")
        #expect(
            MembershipPresentation.settingsAction(for: free)
                == MembershipPresentation.settingsAction(for: free, purchase: .idle)
        )
    }

    // MARK: - The one line under the card

    @Test("the card's purchase line is the sheet's sentence, or nothing")
    func purchaseLineTable() {
        #expect(MembershipPresentation.purchaseLine(for: .late) == PurchaseCopy.late)
        #expect(MembershipPresentation.purchaseLine(for: .awaitingApproval) == PurchaseCopy.approval)
        #expect(MembershipPresentation.purchaseLine(for: .failed("The App Store said no.")) == "The App Store said no.")
        #expect(MembershipPresentation.purchaseLine(for: .idle) == nil)
        #expect(MembershipPresentation.purchaseLine(for: .purchasing) == nil)
        #expect(MembershipPresentation.purchaseLine(for: .confirming) == nil)
        #expect(MembershipPresentation.purchaseLine(for: .subscribed) == nil)
    }

    @Test("the late line is not an error and does not read as one")
    func theLateLineIsCalm() {
        let line = MembershipPresentation.purchaseLine(for: .late) ?? ""
        #expect(line.hasPrefix(PurchaseCopy.lateTitle))
        #expect(line.hasSuffix(PurchaseCopy.lateDetail))
        for phrase in MembershipCopy.bannedPhrases {
            #expect(!MembershipCopy.contains(phrase, in: line), "\"\(phrase)\" in the late line")
        }
    }

    /// Every sentence the card can say about a purchase, against the copy file's banned list.
    @Test("no purchase sentence ships a banned phrase")
    func noBannedPhraseInPurchaseCopy() {
        for string in PurchaseCopy.allUserVisibleStrings {
            for phrase in MembershipCopy.bannedPhrases {
                #expect(!MembershipCopy.contains(phrase, in: string), "\"\(phrase)\" in \"\(string)\"")
            }
        }
    }

    /// The card and the sheet read one source. A reword here changes both, which is the point.
    @Test("the card's late line is the sheet's two sentences, joined")
    func cardAndSheetShareTheSentences() {
        #expect(PurchaseCopy.late == "\(PurchaseCopy.lateTitle) \(PurchaseCopy.lateDetail)")
        #expect(PurchaseCopy.approval == "\(PurchaseCopy.approvalTitle) \(PurchaseCopy.approvalDetail)")
    }

    // MARK: - When a presenter behind the sheet re-reads itself

    @Test(
        "a board reloads on the false → true transition of the household and on nothing else",
        arguments: [
            (Bool?.some(false), Bool?.some(true), true),
            (nil, true, false),
            (true, true, false),
            (true, false, false),
            (false, false, false),
            (nil, nil, false),
            (false, nil, false),
        ]
    )
    func reloadTable(was: Bool?, now: Bool?, reloads: Bool) {
        #expect(MembershipPresentation.boardNeedsReload(wasSubscribed: was, isSubscribed: now) == reloads)
    }

    // MARK: - Helpers

    private func household(tier: String, isPayer: Bool? = nil) -> FamilySummary {
        FamilySummary(
            familyId: UUID(),
            tier: tier,
            access: tier == "subscribed" ? .subscribed : .free,
            lapsedAt: nil,
            plan: nil,
            billingRetry: nil,
            isPayer: isPayer,
            entitled: nil,
            entitlementSource: nil,
            guardians: [],
            pendingInvites: []
        )
    }
}
