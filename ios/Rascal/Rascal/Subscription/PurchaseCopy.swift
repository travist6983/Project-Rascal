import Foundation

/// The sentences a purchase says about itself, in one place so two surfaces cannot drift.
///
/// **Reproduced, not authored.** Every string here shipped in `PaywallSheet` with phase 37b on
/// Aug 20, 2026 — two days before `docs/design/free-tier-copy.md` was reconstructed — and none of
/// them is in that file or in `MembershipCopy`. Phase 140 renders the same sentences on the
/// Settings Membership card, because the sheet now dismisses the moment a purchase leaves the
/// parent's hands and the card is where the outcome is reported. The copy file forbids an agent
/// writing a *new* sentence into a view; moving a shipped one into a constants file so both views
/// read it is the same argument the card's reassurance block already makes for `stayFree`. The
/// reuse is recorded under the copy file's *Proposed additions* for the owner to keep or reword —
/// changing a word here changes it on both surfaces at once, which is the point.
nonisolated enum PurchaseCopy {

    /// `.purchasing` — the App Store's own sheet is up or about to be.
    static let talkingToAppStore = "Talking to the App Store"

    /// `.confirming` — Apple has taken the money and the server has not been told yet. Named for
    /// what is happening rather than for the machinery.
    static let finishingUp = "Finishing up"

    /// `.subscribed`, on the sheet. The card says nothing extra: its status row already reads the
    /// owner's *Subscribed* and the Manage row appears, which is "the normal you have subscription
    /// view" the owner asked for.
    static let subscribedTitle = "You're subscribed. Thank you."
    static let subscribedDetail = "Everything is shared with the household now."

    /// `.late` — the window closed with the server still saying `free`. **Not an error, and it
    /// does not read as one.** The purchase succeeded; the confirmation is late.
    static let lateTitle = "Your membership is being confirmed."
    static let lateDetail = "There's nothing else you need to do — it'll appear here shortly."

    /// `.awaitingApproval` — Ask to Buy, or a bank's challenge. Not a failure either.
    static let approvalTitle = "This purchase needs approval."
    static let approvalDetail = "Once it's approved, the app will notice on its own."

    /// The sheet renders title and detail as two lines; the card has one `metadata` line under
    /// it and joins them with a space. "here" names whichever surface is showing it, which is
    /// truer on the card than it ever was on a sheet that was about to be dismissed.
    static let late = "\(lateTitle) \(lateDetail)"
    static let approval = "\(approvalTitle) \(approvalDetail)"

    /// Everything above that a parent can read, for the banned-phrase guard in `MembershipTests`.
    static var allUserVisibleStrings: [String] {
        [
            talkingToAppStore, finishingUp,
            subscribedTitle, subscribedDetail,
            lateTitle, lateDetail, late,
            approvalTitle, approvalDetail, approval,
        ]
    }
}
