import Foundation

/// Everything this app is allowed to do about notification permission, in one place.
///
/// **iOS grants exactly one system permission prompt, ever.** A denial is effectively permanent:
/// recovery means the parent finding a toggle in iOS Settings, which almost nobody does. So the
/// system prompt is never fired directly. It fires only after the parent has already said yes to
/// an in-app screen — the *soft ask* — which is what keeps a "not right now" from becoming a
/// permanent no.
///
/// The rules encoded here, all of which have a test:
///
/// 1. Nothing reaches `requestAuthorization` except through `acceptSoftAsk`.
/// 2. `declineSoftAsk` never fires the system prompt, so the one-shot survives intact.
/// 3. A "not now" is re-offered **exactly once**, after the first completed entry.
/// 4. **Once the system prompt has been denied, nothing asks again** — not onboarding, not the
///    post-entry offer, not the Settings toggle, not ever. A denied permission is a valid
///    steady state, not a funnel to recover from.
/// 5. A parent who enables notifications in iOS Settings later gets a token registered on the
///    next foreground without being asked anything.
///
/// Nothing here schedules a notification. There is no `UNUserNotificationCenter` scheduling call
/// anywhere in this target — the server owns the schedule, in the child's `family_timezone`.

// MARK: - What the local install remembers

/// The two facts the system cannot tell us.
///
/// `UNUserNotificationCenter` knows whether the prompt was answered; it does not know whether we
/// ever showed the *soft* ask, nor whether the single re-offer has been spent. Those live here.
nonisolated struct NotificationAskRecord: Codable, Equatable, Sendable {
    /// The parent chose "Not now" on the soft ask. The system prompt was never fired.
    var declinedSoftAsk = false
    /// The one permitted re-offer, after the first completed entry, has been shown.
    var reofferSpent = false
}

nonisolated protocol NotificationAskRecording: AnyObject, Sendable {
    func load() -> NotificationAskRecord
    func save(_ record: NotificationAskRecord)
}

nonisolated final class UserDefaultsNotificationAskStore: NotificationAskRecording, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "notifications.ask") {
        self.defaults = defaults
        self.key = key
    }

    /// A record that cannot be decoded reads as a fresh one — the same choice the onboarding
    /// draft and the sync cursor make. The cost is at worst one extra soft ask, which is
    /// harmless; the alternative is a decode failure stranding the feature permanently.
    func load() -> NotificationAskRecord {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(NotificationAskRecord.self, from: data)
        else { return NotificationAskRecord() }
        return record
    }

    func save(_ record: NotificationAskRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }
}

nonisolated final class InMemoryNotificationAskStore: NotificationAskRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var record: NotificationAskRecord

    init(_ record: NotificationAskRecord = NotificationAskRecord()) { self.record = record }

    func load() -> NotificationAskRecord {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    func save(_ record: NotificationAskRecord) {
        lock.lock(); defer { lock.unlock() }
        self.record = record
    }
}

// MARK: - How the row and the screen should read

/// What a permission surface is allowed to offer right now.
///
/// Derived from the live system status plus the local record, never stored. Storing it would let
/// a stale copy offer an ask after the parent had already refused in iOS Settings.
nonisolated enum NotificationOffer: Equatable, Sendable {
    /// The soft ask may run, and through it the system prompt.
    case mayAsk
    /// Already on. Nothing to ask; the surface shows a plain preference.
    case alreadyAuthorized
    /// **Terminal.** The parent refused. The surface explains where the iOS toggle is and asks
    /// nothing. It must not render as an enabled control that silently does nothing.
    case blockedBySystem
}

// MARK: - The machine

@MainActor
@Observable
final class NotificationPreference {

    /// The last known system answer. Refreshed on foreground, never cached across a launch.
    private(set) var systemStatus: NotificationAuthorizationStatus = .notDetermined
    /// Mirrors `notify_enabled` on the server. The server is the source of truth; this is what
    /// the current screen renders while a write is in flight.
    private(set) var notifyEnabled = false
    private(set) var notifyTime: NotifyTime = .default
    /// A `PATCH /v1/me` is in flight. Disables the control that started it.
    private(set) var isWorking = false

    private var record: NotificationAskRecord

    private let authorizer: any NotificationAuthorizing
    private let store: any NotificationAskRecording
    private let backend: any PushBackend

    init(
        authorizer: any NotificationAuthorizing,
        store: any NotificationAskRecording = UserDefaultsNotificationAskStore(),
        backend: any PushBackend
    ) {
        self.authorizer = authorizer
        self.store = store
        self.backend = backend
        self.record = store.load()
    }

    // MARK: What a surface may offer

    var offer: NotificationOffer {
        switch systemStatus {
        case .denied: .blockedBySystem
        case .authorized: .alreadyAuthorized
        case .notDetermined: .mayAsk
        }
    }

    /// Rule 4, stated as one property so no surface has to re-derive it.
    var isPermanentlyRefused: Bool { systemStatus == .denied }

    /// Rule 3. True for exactly one call, and only for a parent who chose "Not now" and has not
    /// since been refused by the system.
    var shouldReofferAfterFirstEntry: Bool {
        record.declinedSoftAsk && !record.reofferSpent && offer == .mayAsk
    }

    /// Consume the single re-offer. Called when the offer is *shown*, not when it is answered,
    /// so a parent who swipes it away has still spent it — the alternative re-shows it after
    /// every entry, which is the nagging this rule exists to prevent.
    func markReofferShown() {
        guard !record.reofferSpent else { return }
        record.reofferSpent = true
        store.save(record)
    }

    // MARK: Reading the world

    /// Re-read the system's answer and reconcile the local mirror with it.
    ///
    /// Called on launch and on every foreground. This is what makes rule 5 work: a parent who
    /// turns notifications on in iOS Settings comes back to an app that registers a token and
    /// asks them nothing.
    func refresh() async {
        systemStatus = await authorizer.status()
        if systemStatus == .authorized {
            await backend.register()
        }
    }

    /// Sign-out. **Called before the session is cleared**, because `DELETE /v1/devices/{token}`
    /// authenticates with the session it is revoking against — see `OnboardingSession.signOut`.
    func revokeDevice() async {
        await backend.revoke()
    }

    /// Seed the mirror from the server's user record.
    func apply(user: UserResponse) {
        notifyEnabled = user.notifyEnabled
        notifyTime = user.notifyLocalTime
    }

    // MARK: The soft ask

    /// The parent said yes to the in-app screen. **This is the only path to the system prompt.**
    ///
    /// Returns the system's answer so a caller can render the outcome without re-reading it.
    /// A denial here is recorded by `systemStatus` alone and is terminal — nothing sets a flag
    /// that could later be cleared into a second ask.
    @discardableResult
    func acceptSoftAsk(time: NotifyTime) async -> NotificationAuthorizationStatus {
        // Rule 4 defended at the door as well as at the surface. A screen that should never have
        // offered still cannot spend a prompt that is already answered.
        guard offer == .mayAsk else { return systemStatus }

        let result = await authorizer.requestAuthorization()
        systemStatus = result

        guard result == .authorized else {
            // Denied. Nothing is written to the server: `notify_enabled` stays false, because a
            // preference saying "on" behind a permission saying "no" is a row that lies.
            return result
        }

        notifyTime = time
        await backend.register()
        await write(enabled: true, time: time)
        return result
    }

    /// The parent said "Not now".
    ///
    /// **This function does not, and must never, touch `authorizer.requestAuthorization`.** That
    /// is the single most important assertion in this phase: the one-shot survives, so the offer
    /// can be made again later and mean something.
    func declineSoftAsk() {
        guard !record.declinedSoftAsk else { return }
        record.declinedSoftAsk = true
        store.save(record)
    }

    // MARK: Writing the preference

    /// The Settings toggle. Routes through the soft ask when permission has never been asked
    /// for, and refuses outright once the system has said no.
    func setEnabled(_ enabled: Bool) async {
        switch offer {
        case .blockedBySystem:
            // Rule 4. The row renders as unavailable; this is the belt to that braces.
            return
        case .mayAsk:
            guard enabled else { return }
            // Turning it on from Settings is itself the soft ask being accepted — the parent
            // reached past a row that says what it does and tapped it.
            await acceptSoftAsk(time: notifyTime)
        case .alreadyAuthorized:
            await write(enabled: enabled, time: nil)
        }
    }

    func setTime(_ time: NotifyTime) async {
        guard time != notifyTime else { return }
        // Only the time. `notify_enabled` is deliberately not resent: the server reads
        // `model_fields_set`, so an omitted key means "no opinion" and a parent changing the
        // time cannot accidentally re-enable a preference they had turned off.
        await write(enabled: nil, time: time)
    }

    /// **Every preference write goes through `PATCH /v1/me` and nothing else.** Nothing in this
    /// type schedules a local notification.
    ///
    /// Optimistic, then reconciled with what the server actually answered — and rolled back if
    /// it never answered. A row left showing "on" after the write that would have made it true
    /// failed is the version of this bug a parent finds out about a week later.
    private func write(enabled: Bool?, time: NotifyTime?) async {
        let previousEnabled = notifyEnabled
        let previousTime = notifyTime
        if let enabled { notifyEnabled = enabled }
        if let time { notifyTime = time }

        isWorking = true
        defer { isWorking = false }
        do {
            let user = try await backend.updatePreference(enabled: enabled, time: time)
            notifyEnabled = user.notifyEnabled
            notifyTime = user.notifyLocalTime
        } catch {
            // Non-fatal and silent, matching registration. The next launch re-reads `/me` and
            // the server's answer wins; surfacing an error here would put a failure banner on a
            // screen the parent has usually already left.
            notifyEnabled = previousEnabled
            notifyTime = previousTime
        }
    }
}
