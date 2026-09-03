import Foundation

/// What this device has already shown the parent about membership.
///
/// **Presentation state, not archive state, and deliberately local.** It records what a screen has
/// done, not anything about the household — so it belongs in `UserDefaults` beside the notification
/// re-offer and the onboarding draft, and never on the server. A reinstall forgetting it is the
/// correct behaviour, not a bug: this is a fact about a phone.
///
/// Shape and idiom copied from `NotificationAskRecord` — a `Codable` record behind a protocol, with
/// an in-memory double — because that is the pattern this app already uses for exactly this job.
nonisolated struct MembershipPresentationRecord: Codable, Equatable, Sendable {
    /// The trial welcome has been shown. One screen, once, ever.
    var trialWelcomeShown = false

    /// A sign-in on this device has **just created a session**, and the welcome has not been spent.
    ///
    /// **This flag is the whole fix for the worst defect this phase shipped in review.** Without it
    /// the rule was `!trialWelcomeShown`, which defaults to `false` for everybody — so the first
    /// launch after updating showed *"Two weeks, everything open. No card, nothing to cancel."* to
    /// a parent who has used the app for months, to an invited second guardian who has no trial of
    /// their own, and, worst, **to a subscribed household**, who would be told they are on a free
    /// trial that ends.
    ///
    /// A resumed session never sets it, so an existing install is silent. `OnboardingSession` sets
    /// it at the four points a sign-in actually exchanges a credential.
    var trialWelcomeOwed = false

    /// The post-trial notice has been shown — **whether or not it was dismissed.**
    ///
    /// Seeing it is what spends it. A notice that comes back because you scrolled past instead of
    /// tapping Dismiss is a nag, which is the thing the copy rules forbid outright.
    var postTrialNoticeShown = false

    /// The last `access` value this device **actually decoded from a server response.**
    ///
    /// Nil until a response has carried one. **`Access.notReported` is never written here** — see
    /// `MembershipPresentation.observing(_:in:)`. Recording "the field was absent" as an
    /// observation would manufacture a `trial → free` flip out of a dropped field.
    var lastObservedAccess: String?
}

nonisolated protocol MembershipPresentationStoring: AnyObject, Sendable {
    func load() -> MembershipPresentationRecord
    func save(_ record: MembershipPresentationRecord)
}

nonisolated final class UserDefaultsMembershipPresentationStore:
    MembershipPresentationStoring, @unchecked Sendable
{
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "membership.presentation") {
        self.defaults = defaults
        self.key = key
    }

    /// A record that cannot be decoded reads as a fresh one — the same choice the onboarding draft,
    /// the sync cursor and the notification ask all make.
    ///
    /// The failure direction is worth stating: a corrupt record means the welcome is shown once
    /// more and the notice may fire once more. Both are recoverable in one tap. The alternative —
    /// treating undecodable as "already shown" — would silently suppress the one screen that
    /// explains what the parent just got.
    func load() -> MembershipPresentationRecord {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(MembershipPresentationRecord.self, from: data)
        else { return MembershipPresentationRecord() }
        return record
    }

    func save(_ record: MembershipPresentationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }
}

nonisolated final class InMemoryMembershipPresentationStore:
    MembershipPresentationStoring, @unchecked Sendable
{
    private let lock = NSLock()
    private var record: MembershipPresentationRecord

    init(_ record: MembershipPresentationRecord = MembershipPresentationRecord()) {
        self.record = record
    }

    func load() -> MembershipPresentationRecord {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func save(_ record: MembershipPresentationRecord) {
        lock.lock()
        defer { lock.unlock() }
        self.record = record
    }
}

/// The two one-time decisions, as **pure functions.**
///
/// Separated from the view and from the store so the case that actually matters — a fresh install
/// whose first response is already `free` — can be asserted without rendering anything or touching
/// `UserDefaults`.
nonisolated enum MembershipPresentation {

    /// Whether the post-trial notice fires on this board.
    ///
    /// **The rule is a transition, not a state**, and that is the whole of it. The phase's prompt
    /// says *"the first Today after `access` flips from `trial` to `free`"* — a flip requires having
    /// seen `trial` on this device first.
    ///
    /// Writing the obvious version instead — `access == .free && !shown` — is wrong, and it fails
    /// on a case that is not rare: **a parent installing the app on a new phone after their trial
    /// has already ended.** Their local record is empty, `access` is `free`, and on their first
    /// ever screen they would be told their trial is over, having never seen one on that device.
    ///
    /// Everything else follows from requiring the prior observation:
    ///
    /// - a server that predates phase 107 sends no `access`, which is never recorded, so nothing
    ///   ever flips and no notice ever fires;
    /// - `subscribed → free` — a lapse — does **not** fire this, because the prior value must be
    ///   `trial`. A lapsing subscriber is not finishing a trial and must not be told they are;
    /// - the admin lever can drive one household `trial → free → trial → free` in an afternoon; the
    ///   first flip shows the notice and `postTrialNoticeShown` eats the rest, which is what
    ///   *"never show it again"* asks for.
    static func shouldShowPostTrialNotice(
        record: MembershipPresentationRecord,
        access: Access
    ) -> Bool {
        guard !record.postTrialNoticeShown else { return false }
        guard access == .free else { return false }
        return record.lastObservedAccess == Access.trial.reportedRawValue
    }

    /// The record after a response carrying `access` has been decoded.
    ///
    /// **Only a reported value is written.** `.notReported` leaves the record untouched, so a
    /// pre-107 server, a dropped field or a response that failed to carry one cannot manufacture an
    /// observation — and therefore cannot manufacture a flip out of the next genuine `free`.
    static func observing(
        _ access: Access,
        in record: MembershipPresentationRecord
    ) -> MembershipPresentationRecord {
        guard let raw = access.reportedRawValue else { return record }
        var updated = record
        updated.lastObservedAccess = raw
        return updated
    }

    /// Which control the membership card offers beneath the status row.
    nonisolated enum MembershipAction: Equatable {
        /// Apple's own subscription sheet.
        case manage
        /// The membership sheet — a household that has not joined.
        case offer
        /// **A purchase is in flight, and the card is where it is reported** (phase 140). The
        /// sheet dismisses the moment Apple takes the money, so the row that would sell the
        /// household something shows instead what is happening to the thing they just bought.
        /// Carries its own label so the view renders it without consulting `purchase` again.
        case finishing(String)
        /// **A purchase Apple has taken and the server has not confirmed** (phase 144): `.late`
        /// and `.awaitingApproval`. The sentence sits in the CTA's slot as a plain row and *Become
        /// a member* is gone, because a parent who has just paid must not be invited, in the
        /// card's loudest colour, to do it again and meet Apple's "You're currently subscribed"
        /// dialog. Until phase 144 these kept the offer row and said the sentence under the card.
        case reported(String)
        /// **Neither, and no row at all.** Two households reach it: a subscribed one whose caller
        /// is explicitly *not* the payer, and (since phase 141) one entitled by an admin grant.
        /// There is no approved copy naming the other parent, and none for a complimentary
        /// membership, so the card says nothing rather than inventing a sentence for either.
        case hidden
    }

    /// **What the membership card offers, as a pure function.**
    ///
    /// `hidden` has two states. For a subscriber it is reachable only on an **explicit `false`**:
    /// `is_payer` is null in exactly the two-guardian case — the one case where the question is
    /// meaningful — and hiding Apple's management sheet on a null would strip a working control
    /// from a parent who is paying. `FamilySummary.mayManageSubscription` is the `!= false` that
    /// makes unknown behave as yes. The second is a granted household (phase 141), below.
    ///
    /// **`offer` when there is no household yet**, which is the shipped behaviour and is not this
    /// phase's question to reopen.
    ///
    /// **Keyed on `tier`, not `access`, and deliberately.** Manage opens *Apple's* subscription
    /// sheet, and a household inside its server-granted trial has no Apple subscription to manage —
    /// there is nothing there for them to see. `access` answers what may be *served*; this answers
    /// whether somebody is paying Apple, which is `tier`'s question and always was. **A grant is
    /// the one state `tier` and `access` cannot describe between them**, which is why
    /// `entitlement_source` is read here too (phase 141).
    static func settingsAction(
        for household: FamilySummary?,
        purchase: SubscriptionModel.PurchasePhase = .idle
    ) -> MembershipAction {
        // **The server wins.** A household it already calls subscribed is managed, whatever the
        // local purchase machinery is doing — a purchase that raced a foreground read is not a
        // reason to hide the Manage row from a member.
        if let household, household.isSubscribed {
            return household.mayManageSubscription ? .manage : .hidden
        }
        switch purchase {
        case .purchasing: return .finishing(PurchaseCopy.talkingToAppStore)
        case .confirming: return .finishing(PurchaseCopy.finishingUp)
        // `.late` and `.awaitingApproval` displace the offer row with their sentence (phase
        // 144), for a granted household too — a grant landing while a purchase is late must not
        // hide what the purchase has to say. `.failed` keeps the offer for the retry that lives
        // on the sheet, beside Terms and Privacy, which the card cannot carry.
        case .late: return .reported(PurchaseCopy.late)
        case .awaitingApproval: return .reported(PurchaseCopy.approval)
        case .idle, .failed, .subscribed:
            // **A granted household is neither.** The status row above it already reads
            // *Subscribed* (`settingsHeader` keys on `tier` first, and a grant reads `subscribed`
            // there by the server's deliberate choice), there is no Apple subscription for Manage
            // to open, and offering to sell membership to a household that has all of it is the
            // contradiction phase 141 found: "Subscribed" with "See what membership includes"
            // directly beneath. No row, as the explicit-non-payer case already does for the same
            // reason — there is no approved copy for a complimentary membership, so the card says
            // nothing rather than inventing it. After the busy states, not before them: a grant
            // landing while a purchase is mid-flight must not hide "Finishing up".
            if let household, household.isGranted { return .hidden }
            return .offer
        }
    }

    /// Whether the paywall should dismiss itself on this transition of `purchase`.
    ///
    /// **Only the entry into `.confirming`**, which is the moment the purchase has left the
    /// parent's hands: Apple has the money and the server is being told. Everything before it
    /// (`.purchasing`, a `.failed` with its retry, an `.awaitingApproval` the parent may be
    /// watching for) stays on the sheet; everything after it is the card's to report. An
    /// Ask-to-Buy approval landing while the sheet is open enters `.confirming` by
    /// `transactionArrived()` and dismisses the same way — one rule rather than two.
    static func dismissAfterPurchase(
        from old: SubscriptionModel.PurchasePhase,
        to new: SubscriptionModel.PurchasePhase
    ) -> Bool {
        new == .confirming && old != .confirming
    }

    /// The one line the Membership card says under itself about a purchase, if anything.
    ///
    /// **Only `.failed`, since phase 144.** `.late` and `.awaitingApproval` moved into the card as
    /// `MembershipAction.reported`, and a sentence rendered in the card must not also render under
    /// it. `.failed` carries the store's own sentence — the sheet keeps its retry, but a parent who
    /// swiped it away unread should still find the reason on the card. `.confirming` and
    /// `.purchasing` are the busy row, not a line; `.subscribed` needs no sentence because the
    /// header already names the membership.
    static func purchaseLine(for purchase: SubscriptionModel.PurchasePhase) -> String? {
        switch purchase {
        case .failed(let message): return message
        case .idle, .purchasing, .confirming, .late, .awaitingApproval, .subscribed: return nil
        }
    }

    /// Which detail sits under *Become a member*.
    ///
    /// The trial's own sentence rather than §2's subtitle, because the header two lines up says
    /// the household already has everything — *"Membership is what fills in the rest of the day"*
    /// reads as false on a full board, or as "membership starts after the trial", and the second
    /// reading is the dangerous one: Apple grants no introductory offer, so joining on day three
    /// charges on day three. The row that sends a parent into that charge is the row that says so.
    static func offerDetail(for household: FamilySummary?) -> String {
        household?.access == .trial
            ? MembershipCopy.Card.offerDetailTrial
            : MembershipCopy.Card.offerDetail
    }

    /// Which detail sits under *Manage subscription*: the retry variant names where the payment
    /// method lives, because a parent whose card is failing will tap the one action on the card
    /// and Apple's manage-subscriptions sheet does not reach a payment field.
    static func manageDetail(for household: FamilySummary?) -> String {
        household?.isInBillingRetry == true
            ? MembershipCopy.Card.manageDetailRetry
            : MembershipCopy.Card.manageDetail
    }

    /// Whether the card offers *Restore a purchase*, and in what state.
    nonisolated enum RestoreRow: Equatable {
        /// Tappable.
        case offered
        /// Present and disabled: a purchase is mid-flight, and two StoreKit operations must not
        /// overlap — nor should the card reflow the moment the sheet dismisses itself.
        case waiting
        /// Not on the card at all.
        case hidden
    }

    /// **Restore appears only where a restore could find something** (phase 144).
    ///
    /// For a household the server already calls a member, `restore()` can only re-read the same
    /// answer — a submission may only ever promote, and there is nothing to promote — so the row
    /// would be furniture whose one outcome confirms the line above it. The Sep 2 incident the row
    /// exists for (a receipt this phone held that the server could not see) reads as `free` or
    /// `trial` in every version of the story, because the server not knowing about a purchase is
    /// exactly what makes `access` not `subscribed`. So: hidden for every member state whatever
    /// `purchase` says; disabled while a purchase is in flight; enabled again in `.late` and
    /// `.awaitingApproval`, where it is the one control on the card that can nudge the server.
    /// App Review's restore requirement is met by the paywall, which every non-member state reaches
    /// through *Become a member*.
    static func settingsRestore(
        for household: FamilySummary?,
        purchase: SubscriptionModel.PurchasePhase = .idle
    ) -> RestoreRow {
        if let household, household.isMember { return .hidden }
        switch purchase {
        case .purchasing, .confirming: return .waiting
        case .idle, .late, .awaitingApproval, .failed, .subscribed: return .offered
        }
    }

    /// Whether a presenter behind the sheet should re-read its own screen because the household
    /// just became subscribed.
    ///
    /// **Only the false → true transition.** `nil` is a household not yet read, and reloading on
    /// `nil → true` would re-fetch every screen on the first read of an already-subscribed
    /// household; `true → true` is a foreground re-read confirming what was known. Observing the
    /// household rather than `purchase` is deliberate: it is the server's word (D5), it fires for
    /// a membership that lands by any door — another guardian's purchase seen on a foreground
    /// read, a restore — and it cannot fire on a local receipt.
    static func boardNeedsReload(wasSubscribed: Bool?, isSubscribed: Bool?) -> Bool {
        wasSubscribed == false && isSubscribed == true
    }

    /// **Whether a restore that has just finished should close the paywall.**
    ///
    /// A pure function, in the presentation layer, and deliberately **not** inside
    /// `SubscriptionModel.restore()`. The same `restore()` is called from `SubscriptionSection`,
    /// where a success must leave the parent on the Settings screen they were reading. A shared
    /// implementation that dismissed would need a flag threaded through it; a *caller* that decides
    /// needs nothing. And because exactly one sentence says what "success" means, the two surfaces
    /// cannot drift into disagreeing about it.
    ///
    /// **The device does not decide entitlement (D5).** `household` is the `FamilySummary` that
    /// `EntitlementConfirmation.poll` read back from `GET /v1/families/me`; `isSubscribed` is the
    /// server's word on it. Nothing here does arithmetic, reads a receipt, or consults StoreKit.
    /// It is `isMember` rather than `access.isEntitled` on purpose: that is the same predicate
    /// the sheet's own **Done** button keys on (a receipt or a grant, since phase 141), so this
    /// cannot dismiss over a state the sheet would have described differently.
    ///
    /// **`notice` is what separates the outcomes, and it is load-bearing rather than
    /// belt-and-braces.** `restore()` clears it before it starts and writes it in exactly three
    /// places: a refused `AppStore.sync()`, a window that closed with nothing having arrived, and
    /// (since phase 143) a receipt the server says is another household's. So nil means the sync
    /// succeeded *and* the receipt was not refused *and* the poll was not the not-found branch —
    /// which is what stops a parent whose household was **already** subscribed when they tapped
    /// from being dismissed out of the sheet by a restore that just failed, over an error they never
    /// read.
    static func dismissAfterRestore(household: FamilySummary?, notice: String?) -> Bool {
        guard notice == nil else { return false }
        return household?.isMember == true
    }

    /// The two lines at the head of the Membership card.
    nonisolated struct MembershipHeader: Equatable {
        /// What the household is on, in a noun. Never a claim the server did not make.
        let headline: String
        /// The one dated fact the server sent, formatted and never counted here — or the sentence
        /// that says why there is none.
        let detail: String?
    }

    /// **What the Membership card's header reports** — a pure function of the household, for the
    /// same reason the functions above are: every state can be asserted without rendering a view
    /// or touching a clock.
    ///
    /// Phase 144 replaced `settingsStatus(for:)`, whose four one-word answers were the owner's
    /// complaint: *"Everything open"* named neither the trial nor its end, and *"Subscribed"* said
    /// nothing about which plan or until when. The headline now keys on the same fields in the
    /// same order — `tier` (Apple's word) first, then a grant, then `access` — and the detail is
    /// the design doc's presence table (`docs/design/membership-card-redesign.md` §3), read from
    /// the wire and nowhere else.
    ///
    /// **Nothing here is arithmetic.** The dates are the server's instants through the formatter
    /// Settings already uses for a dated commitment, and the day count is the server's
    /// `trial_days_left`. `SettingsMembershipTests.theRowDoesNoArithmetic` scans this file for the
    /// alternative.
    static func settingsHeader(for household: FamilySummary?) -> MembershipHeader {
        guard let household else {
            return MembershipHeader(
                headline: MembershipCopy.Card.unknown, detail: MembershipCopy.Card.noAnswerYet
            )
        }
        if household.isSubscribed {
            return MembershipHeader(
                headline: planHeadline(for: household), detail: subscribedDetail(for: household)
            )
        }
        if household.isGranted {
            let detail = household.grantExpiresAt.map {
                MembershipCopy.render(
                    MembershipCopy.Card.complimentaryUntil, date: DayHeaderText.dayAndMonth($0)
                )
            }
            return MembershipHeader(
                headline: MembershipCopy.Card.complimentary,
                detail: detail ?? MembershipCopy.Card.complimentaryDetail
            )
        }
        switch household.access {
        case .trial:
            return MembershipHeader(
                headline: MembershipCopy.Card.trial, detail: trialDetail(for: household)
            )
        case .free, .notReported, nil:
            // A server predating phase 107 sends no `access`, and on such a server `tier` is the
            // whole truth — `isSubscribed` above already answered for it.
            return MembershipHeader(
                headline: MembershipCopy.Card.free, detail: MembershipCopy.Card.freeDetail
            )
        case .subscribed:
            // `access` says subscribed, `tier` says free, and no `entitlement_source` says grant:
            // a server predating phase 121 holding a grant. "Membership" claims neither a cadence
            // nor Apple's word, and the offer row beneath it is today's answer, named rather than
            // fixed.
            return MembershipHeader(headline: MembershipCopy.Card.membership, detail: nil)
        case .unrecognised:
            // D9: entitled, never claimed. The board stays open; the card says why it cannot name
            // the membership rather than naming the wrong one.
            return MembershipHeader(
                headline: MembershipCopy.Card.unknown, detail: MembershipCopy.Card.unreadable
            )
        }
    }

    /// `Annual membership` / `Monthly membership` / `Membership`. A lookup, never a substring
    /// parse, and a cadence this build has never heard of is the plain noun.
    private static func planHeadline(for household: FamilySummary) -> String {
        switch household.plan {
        case "annual": MembershipCopy.Card.annual
        case "monthly": MembershipCopy.Card.monthly
        default: MembershipCopy.Card.membership
        }
    }

    /// *Renews* / *Expires* / *Paid through*, by Apple's word — or nothing, when the server sent
    /// no period end (an older server, a receipt-less subscription, a billing retry).
    private static func dateLine(for household: FamilySummary) -> String? {
        guard let expiresAt = household.expiresAt else { return nil }
        let date = DayHeaderText.dayAndMonth(expiresAt)
        switch household.autoRenew {
        case .some(true): return MembershipCopy.render(MembershipCopy.Card.renews, date: date)
        case .some(false): return MembershipCopy.render(MembershipCopy.Card.expires, date: date)
        case .none: return MembershipCopy.render(MembershipCopy.Card.paidThrough, date: date)
        }
    }

    private static func subscribedDetail(for household: FamilySummary) -> String? {
        if household.isPayer == false {
            // The date line when there is one, then who manages it. Never the retry sentence: it
            // is an offer to fix, and this parent cannot fix it. Never the pointer either — it is
            // about an App Store this parent cannot reach.
            let line = household.isInBillingRetry ? nil : dateLine(for: household)
            return [line, MembershipCopy.Card.otherParent].compactMap { $0 }.joined(separator: ". ")
        }
        if household.isInBillingRetry { return MembershipCopy.Card.billingRetry }
        guard let line = dateLine(for: household) else { return nil }
        // "Paid through" leaves the question open; the pointer answers it, at the Manage row. A
        // date line stands alone without a full stop and takes one when a sentence follows it.
        return household.autoRenew == nil ? line + ". " + MembershipCopy.Card.paidThroughPointer : line
    }

    /// The count and the date, both the server's. **The count renders only beside the date**:
    /// `trial_days_left` without `trial_ends_at` is a server this build has never met, and a
    /// bare number is the countdown the copy rules ban.
    private static func trialDetail(for household: FamilySummary) -> String {
        guard let endsAt = household.trialEndsAt else { return MembershipCopy.Card.trialDetailNoDate }
        let date = DayHeaderText.dayAndMonth(endsAt)
        switch household.trialDaysLeft {
        case .none:
            return MembershipCopy.render(MembershipCopy.Card.trialDetailDateOnly, date: date)
        case .some(let days) where days <= 1:
            return MembershipCopy.render(MembershipCopy.Card.trialDetailLastDay, date: date)
        case .some(let days):
            return MembershipCopy.render(MembershipCopy.Card.trialDetail, date: date, days: days)
        }
    }

    /// Whether the trial welcome is owed.
    ///
    /// **Two conditions, and the first one is the one that was missing.** A sign-in on this device
    /// must have just created a session — not merely "the flag has never been spent", which is true
    /// of every install that has never seen this build and which therefore showed a two-weeks
    /// welcome to months-old accounts, to invited guardians, and to paying subscribers.
    ///
    /// **Still not conditioned on `access`, and that part was right.** This screen comes *before*
    /// the first Today and `access` arrives *with* it, so gating on the value would show this after
    /// the screen it is meant to precede. The missing condition was never `access`; it was
    /// "did somebody just sign in", which is known at sign-in time without waiting for a board.
    static func shouldShowTrialWelcome(record: MembershipPresentationRecord) -> Bool {
        record.trialWelcomeOwed && !record.trialWelcomeShown
    }

    /// A sign-in has just exchanged a credential and established a session.
    ///
    /// **Never re-arms a spent welcome.** Signing out and back in on the same device does not earn
    /// a second one: the screen explains the two weeks, and the two weeks belong to the household
    /// rather than to the session.
    static func owingWelcome(in record: MembershipPresentationRecord) -> MembershipPresentationRecord {
        guard !record.trialWelcomeShown else { return record }
        var updated = record
        updated.trialWelcomeOwed = true
        return updated
    }

    /// This device arrived by invitation, so there is no two weeks to welcome anybody to.
    ///
    /// An invited second guardian joins a household that already exists and whose trial, if it ever
    /// had one, is not theirs and may long since have ended. Spending the welcome rather than
    /// merely un-owing it is deliberate: they should not be shown it later either, and the
    /// household is the unit (D4).
    static func decliningWelcome(
        in record: MembershipPresentationRecord
    ) -> MembershipPresentationRecord {
        var updated = record
        updated.trialWelcomeOwed = false
        updated.trialWelcomeShown = true
        return updated
    }
}
