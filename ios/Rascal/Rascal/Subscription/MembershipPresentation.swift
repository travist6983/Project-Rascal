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

    /// Whether the trial welcome is owed.
    ///
    /// Once per install, and **not conditioned on `access`** — deliberately. The welcome is shown
    /// before the first Today, and `access` arrives *with* the first Today, so gating on it would
    /// mean showing this after the screen it is supposed to precede. The copy is written to be true
    /// of any household that has just signed in for the first time on this device.
    static func shouldShowTrialWelcome(record: MembershipPresentationRecord) -> Bool {
        !record.trialWelcomeShown
    }
}
