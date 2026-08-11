import Foundation

/// Where the parent is in first-run setup, and what they have typed so far.
///
/// Persisted after every step so a kill mid-onboarding resumes where it left off with the input
/// intact. Cleared the moment the child exists on the server — at that point the server's copy
/// is the truth and a stale local draft could only ever contradict it.

// MARK: - Steps

/// The five screens between "signed in" and "has a child". Ordered, and the order is the
/// progress bar's denominator.
///
/// `notifications` is last on purpose. It is the only step that spends something irreversible —
/// iOS shows the system permission prompt once, ever — and putting it after the parent has
/// already named their kid and picked a photo means the ask arrives to someone who has decided
/// to use this, not to someone still deciding.
nonisolated enum OnboardingStep: String, CaseIterable, Codable, Equatable, Sendable {
    case name
    case birthdate
    case timezone
    case avatar
    case notifications

    /// 1-based, for "step 2 of 4" and for the progress fill.
    var ordinal: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    static var count: Int { allCases.count }

    var next: OnboardingStep? {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return index + 1 < Self.allCases.count ? Self.allCases[index + 1] : nil
    }

    var previous: OnboardingStep? {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return index > 0 ? Self.allCases[index - 1] : nil
    }
}

// MARK: - The draft

nonisolated struct OnboardingDraft: Codable, Equatable, Sendable {
    var step: OnboardingStep = .name
    var name: String = ""
    /// `yyyy-MM-dd`, or nil until the parent has confirmed one. Stored in wire form rather than
    /// as a `Date` so what is persisted is exactly what will be sent — a draft that round-trips
    /// through a timezone on its way to disk is a birthdate that can drift by a day.
    var birthdate: String?
    /// Defaults to the device zone at the point the draft is created, not at the point it is
    /// read, so a parent who starts setup on a plane does not get a different answer on landing.
    var timezone: String = TimeZoneCatalog.deviceZone
    /// What the parent set on the notification step before answering it. **Optional so a draft
    /// written by the previous build still decodes** — a non-optional property with a default is
    /// still decoded with `decode` rather than `decodeIfPresent`, and would throw on every draft
    /// already on disk. Nil means "has not touched the picker", which reads as `NotifyTime`'s
    /// default and is the same time the server would have used.
    var notifyTime: NotifyTime?

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The server enforces `min_length=1, max_length=200`. Matching it here means the parent
    /// finds out at the keyboard rather than after a round trip.
    static let nameLimit = 200

    var isNameValid: Bool {
        !trimmedName.isEmpty && trimmedName.count <= Self.nameLimit
    }
}

// MARK: - The birthdate bound and the age echo

/// The rule the birthdate picker is built on: **nothing after today is selectable.**
///
/// This replaced a `BirthdateCheck`/`.inTheFuture` pair that rendered "That's still ahead of us.
/// Check the year." under a disabled Continue. The picker was unbounded, so a future date was
/// reachable, and — because the step writes the draft through on every change — a future date
/// was also *persistable*. A parent who spun the wheel forward and then put the phone down came
/// back to the first real screen of the app opening on an error they had not made yet, with the
/// only way forward disabled.
///
/// Bounding the picker at `...Date()` makes that state unreachable, so the error state is gone
/// rather than left standing behind a condition that can no longer be true. What survives is the
/// clamp, and it is not validation — it is the migration for drafts already written to disk by
/// the build that had no bound.
nonisolated enum BirthdateRule {
    /// The latest selectable birthdate: today.
    ///
    /// A birthdate is a calendar day, so this is a comparison of *days* and not of instants.
    /// Clamping on the raw `Date`s would move a birthday of today backwards for every hour
    /// between midnight and now.
    static func clamped(
        _ birthdate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let day = calendar.startOfDay(for: birthdate)
        let today = calendar.startOfDay(for: now)
        return day > today ? now : birthdate
    }
}

/// The age shown back to the parent while they are still setting up.
///
/// **This is the one place on the client that computes an age, and it is deliberately not for
/// the archive.** `AgeText` says plainly that nothing in it calculates an age, and that stands:
/// every age *on an entry* is `child_age_months`, computed server-side at write and stored, so a
/// rounding or timezone difference can never reshape the archive.
///
/// What this computes is a confirmation echo — "4 years, 2 months" under a date the parent just
/// spun a wheel to. It exists because it catches a mistyped year far better than validation
/// does, and it is never stored, never sent, and never stamped on anything. The child does not
/// exist on the server yet, so there is no server answer to render instead.
nonisolated enum DraftAge {
    static func months(
        from birthdate: Date,
        to now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let from = calendar.startOfDay(for: birthdate)
        let to = calendar.startOfDay(for: now)
        guard from <= to else { return 0 }
        return calendar.dateComponents([.month], from: from, to: to).month ?? 0
    }

    /// "4 years, 2 months" — the long form, matching what Entry Detail says beside an age.
    static func label(from birthdate: Date, to now: Date = Date()) -> String {
        AgeText.long(months(from: birthdate, to: now))
    }

    static func spoken(from birthdate: Date, to now: Date = Date()) -> String {
        AgeText.spoken(months(from: birthdate, to: now))
    }
}

// MARK: - Persistence

nonisolated protocol OnboardingDraftStoring: AnyObject, Sendable {
    func load() -> OnboardingDraft?
    func save(_ draft: OnboardingDraft)
    func clear()
}

nonisolated final class UserDefaultsOnboardingDraftStore: OnboardingDraftStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "onboarding.draft") {
        self.defaults = defaults
        self.key = key
    }

    /// A draft that cannot be decoded is treated as absent — the same choice the sync cursor and
    /// the user record make. The recovery is retyping a first name, and honouring half a record
    /// would put a nonsensical value on screen with no way to work out why.
    func load() -> OnboardingDraft? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OnboardingDraft.self, from: data)
    }

    func save(_ draft: OnboardingDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

nonisolated final class InMemoryOnboardingDraftStore: OnboardingDraftStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OnboardingDraft?

    init(_ draft: OnboardingDraft? = nil) { self.stored = draft }

    func load() -> OnboardingDraft? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ draft: OnboardingDraft) {
        lock.lock(); defer { lock.unlock() }
        stored = draft
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
