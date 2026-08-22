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
        /// **Neither, and no row at all.** A subscribed household whose caller is explicitly *not*
        /// the payer. There is no approved copy naming the other parent, so the card says nothing
        /// rather than inventing a sentence about somebody else's card.
        case hidden
    }

    /// **What the membership card offers, as a pure function.**
    ///
    /// `hidden` exists only for one state and is reachable only on an **explicit `false`**:
    /// `is_payer` is null in exactly the two-guardian case — the one case where the question is
    /// meaningful — and hiding Apple's management sheet on a null would strip a working control
    /// from a parent who is paying. `FamilySummary.mayManageSubscription` is the `!= false` that
    /// makes unknown behave as yes.
    ///
    /// **`offer` when there is no household yet**, which is the shipped behaviour and is not this
    /// phase's question to reopen.
    ///
    /// **Keyed on `tier`, not `access`, and deliberately.** Manage opens *Apple's* subscription
    /// sheet, and a household inside its server-granted trial has no Apple subscription to manage —
    /// there is nothing there for them to see. `access` answers what may be *served*; this answers
    /// whether somebody is paying Apple, which is `tier`'s question and always was.
    static func settingsAction(for household: FamilySummary?) -> MembershipAction {
        guard let household, household.isSubscribed else { return .offer }
        return household.mayManageSubscription ? .manage : .hidden
    }

    /// **What the Settings *Household* row reports.** A pure function, for the same reason the two
    /// above are: the case that matters — a household three days into its trial — can then be
    /// asserted without rendering a view or touching `UserDefaults`.
    ///
    /// **It reads `access`, never `tier`, and that is the defect phase 112 fixes.** `tier` is
    /// constrained to `free | subscribed` and has no word for a trial, so from phase 37a until now
    /// this row told a household inside its two weeks that it was **Free**.
    ///
    /// Four answers, and the two null cases are deliberately *different*:
    ///
    /// * **No household yet** — the server has not answered. `—`, because not knowing is a
    ///   different answer from `free` and this row must not claim on the strength of never
    ///   having looked.
    /// * **`access` absent** — a server predating phase 107, where `tier` is the whole truth
    ///   rather than a lossy half of it, because such a server has no trial to be wrong about.
    ///   Falling back to it is the only correct answer available and keeps every pre-107 build
    ///   behaving exactly as it did.
    /// * **A word this build does not know** — `—`. Under D9 an unrecognised `access` still means
    ///   *entitled*, and `Access.isEntitled` is untouched and still enforces that; but "entitled"
    ///   is not the claim "Subscribed", and naming the wrong membership is worse than naming none.
    ///
    /// **Nothing here is arithmetic.** No `trial_ends_at`, no date, no StoreKit receipt — the
    /// server said a word and this maps it. The device never decides entitlement.
    static func settingsStatus(for household: FamilySummary?) -> String {
        guard let household else { return MembershipCopy.Status.unknown }

        guard let access = household.access else {
            return household.isSubscribed
                ? MembershipCopy.Status.subscribed
                : MembershipCopy.Status.free
        }

        switch access {
        case .subscribed: return MembershipCopy.Status.subscribed
        case .trial: return MembershipCopy.Status.everythingOpen
        case .free: return MembershipCopy.Status.free
        case .unrecognised, .notReported: return MembershipCopy.Status.unknown
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
