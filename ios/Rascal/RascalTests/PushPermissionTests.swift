import Foundation
import Testing

@testable import Rascal

/// Phase 14's permission rules, asserted where they live.
///
/// The single most important assertion in this file is `notNowNeverFiresTheSystemPrompt`. iOS
/// grants exactly one system prompt per install; spending it on a parent who has not already said
/// yes turns "not right now" into a permanent no, and nothing in the app can undo that.

// MARK: - Doubles

/// Counts prompts. **A test asserting "the prompt did not fire" is worthless unless the counter
/// is real**, so this records every call rather than only the last one.
final class StubAuthorizer: NotificationAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: NotificationAuthorizationStatus
    private var _answer: NotificationAuthorizationStatus
    private var _promptCount = 0
    private var _registerCount = 0
    private var _promptsForbidden = false

    init(
        status: NotificationAuthorizationStatus = .notDetermined,
        answersWith answer: NotificationAuthorizationStatus = .authorized
    ) {
        self._status = status
        self._answer = answer
    }

    var promptCount: Int { lock.lock(); defer { lock.unlock() }; return _promptCount }
    var registerCount: Int { lock.lock(); defer { lock.unlock() }; return _registerCount }

    /// Arm the tripwire.
    ///
    /// **Counting after the fact is not enough.** A prompt fired from a detached `Task` — which
    /// is the only way a synchronous function like `declineSoftAsk` could fire one — lands after
    /// the assertion has already read the counter, so the test passes while the defect ships.
    /// This records the failure from inside the call itself, so it is caught whenever it
    /// happens and on whatever thread.
    func forbidPrompts() {
        lock.lock(); defer { lock.unlock() }
        _promptsForbidden = true
    }

    func set(status: NotificationAuthorizationStatus) {
        lock.lock(); defer { lock.unlock() }
        _status = status
    }

    func status() async -> NotificationAuthorizationStatus {
        lock.withLock { _status }
    }

    @discardableResult
    func requestAuthorization() async -> NotificationAuthorizationStatus {
        // `Issue.record` runs outside the lock, exactly as it did before: recording a failure
        // while holding it would put Swift Testing's machinery inside this critical section.
        let (forbidden, answer) = lock.withLock {
            _promptCount += 1
            _status = _answer
            return (_promptsForbidden, _answer)
        }
        if forbidden {
            Issue.record("The system permission prompt fired on a path that must never fire it.")
        }
        return answer
    }

    func registerForRemoteNotifications() async {
        lock.withLock { _registerCount += 1 }
    }
}

/// Records what reached the server, in order.
final class StubPushBackend: PushBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var _user: UserResponse
    private var _failWrites = false

    init(user: UserResponse = .stub()) { self._user = user }

    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }

    func failWrites() {
        lock.lock(); defer { lock.unlock() }
        _failWrites = true
    }

    func register() async {
        lock.withLock { _events.append("register") }
    }

    func revoke() async {
        lock.withLock { _events.append("revoke") }
    }

    func updatePreference(enabled: Bool?, time: NotifyTime?) async throws -> UserResponse {
        let (shouldFail, current) = lock.withLock {
            _events.append("patch(enabled: \(enabled.map(String.init) ?? "-"), time: \(time?.wire ?? "-"))")
            return (_failWrites, _user)
        }
        if shouldFail { throw APIError.transport("offline") }
        let updated = UserResponse(
            id: current.id,
            email: current.email,
            displayName: current.displayName,
            isAdmin: current.isAdmin,
            createdAt: current.createdAt,
            notifyEnabled: enabled ?? current.notifyEnabled,
            notifyLocalTime: time ?? current.notifyLocalTime
        )
        lock.withLock { _user = updated }
        return updated
    }
}

extension UserResponse {
    static func stub(
        notifyEnabled: Bool = false,
        notifyLocalTime: NotifyTime = .default
    ) -> UserResponse {
        UserResponse(
            id: UUID(),
            email: "parent@example.com",
            displayName: "Parent",
            isAdmin: false,
            createdAt: Date(timeIntervalSince1970: 0),
            notifyEnabled: notifyEnabled,
            notifyLocalTime: notifyLocalTime
        )
    }
}

@MainActor
private func makePreference(
    status: NotificationAuthorizationStatus = .notDetermined,
    answersWith answer: NotificationAuthorizationStatus = .authorized,
    record: NotificationAskRecord = NotificationAskRecord()
) -> (NotificationPreference, StubAuthorizer, StubPushBackend) {
    let authorizer = StubAuthorizer(status: status, answersWith: answer)
    let backend = StubPushBackend()
    let preference = NotificationPreference(
        authorizer: authorizer,
        store: InMemoryNotificationAskStore(record),
        backend: backend
    )
    return (preference, authorizer, backend)
}

// MARK: - The soft ask

@MainActor
@Suite("Notification permission — the soft ask")
struct NotificationSoftAskTests {

    /// **The assertion this whole phase is built around.**
    @Test("\"Not now\" never fires the system prompt")
    func notNowNeverFiresTheSystemPrompt() async {
        let (preference, authorizer, backend) = makePreference()
        await preference.refresh()
        authorizer.forbidPrompts()

        preference.declineSoftAsk()

        // Give anything `declineSoftAsk` might have spawned a chance to run before reading the
        // counter. Yields rather than a sleep — a fixed interval is the flake this suite has
        // already been bitten by, and a yield drains the queue deterministically.
        for _ in 0..<10 { await Task.yield() }

        #expect(authorizer.promptCount == 0)
        // And nothing was written either: a preference row saying "on" behind a permission
        // nobody has been asked for would be a lie the server then acts on.
        #expect(backend.events.contains(where: { $0.hasPrefix("patch") }) == false)
        // The one-shot survives, which is the entire point of declining rather than prompting.
        #expect(preference.offer == .mayAsk)
    }

    @Test("\"Turn it on\" fires the system prompt exactly once")
    func turnItOnFiresOnce() async {
        let (preference, authorizer, _) = makePreference()
        await preference.refresh()

        await preference.acceptSoftAsk(time: .default)

        #expect(authorizer.promptCount == 1)

        // A second accept — a double tap, or a Settings toggle afterwards — must not spend
        // another prompt. `offer` is no longer `.mayAsk`, so the guard turns it away.
        await preference.acceptSoftAsk(time: .default)
        #expect(authorizer.promptCount == 1)
    }

    @Test("A grant registers the device and writes the preference")
    func grantRegistersAndWrites() async {
        let (preference, _, backend) = makePreference()
        await preference.refresh()

        await preference.acceptSoftAsk(time: NotifyTime(hour: 8, minute: 30))

        #expect(backend.events.contains("register"))
        #expect(backend.events.contains("patch(enabled: true, time: 08:30:00)"))
        #expect(preference.notifyEnabled)
        #expect(preference.notifyTime == NotifyTime(hour: 8, minute: 30))
    }

    @Test("A system denial writes no preference — a row saying on would be a lie")
    func denialWritesNothing() async {
        let (preference, authorizer, backend) = makePreference(answersWith: .denied)
        await preference.refresh()

        let result = await preference.acceptSoftAsk(time: .default)

        #expect(result == .denied)
        #expect(authorizer.promptCount == 1)
        #expect(backend.events.contains(where: { $0.hasPrefix("patch") }) == false)
        #expect(preference.notifyEnabled == false)
        #expect(preference.offer == .blockedBySystem)
    }
}

// MARK: - Never again after a system denial

@MainActor
@Suite("Notification permission — a denial is terminal")
struct NotificationDenialTests {

    @Test("A denied system permission is never re-prompted, by any mechanism")
    func denialIsNeverRePrompted() async {
        let (preference, authorizer, backend) = makePreference(status: .denied)
        await preference.refresh()

        #expect(preference.offer == .blockedBySystem)
        #expect(preference.isPermanentlyRefused)

        // 1. The onboarding path.
        await preference.acceptSoftAsk(time: .default)
        // 2. The Settings toggle.
        await preference.setEnabled(true)
        // 3. The post-entry re-offer never even becomes available.
        #expect(preference.shouldReofferAfterFirstEntry == false)

        #expect(authorizer.promptCount == 0)
        #expect(backend.events.contains(where: { $0.hasPrefix("patch") }) == false)
    }

    @Test("A denial after a deferral still closes the post-entry re-offer")
    func denialAfterDeferralClosesReoffer() async {
        let (preference, authorizer, _) = makePreference(
            record: NotificationAskRecord(declinedSoftAsk: true)
        )
        await preference.refresh()
        #expect(preference.shouldReofferAfterFirstEntry)

        // The parent went to iOS Settings and turned notifications off outright.
        // Nothing about having deferred earlier survives that.
        authorizer.set(status: .denied)
        await preference.refresh()

        #expect(preference.shouldReofferAfterFirstEntry == false)
        #expect(preference.offer == .blockedBySystem)
    }

    @Test("The Settings toggle reflects a denial rather than showing an enabled state")
    func settingsToggleReflectsDenial() async {
        let (preference, _, backend) = makePreference(status: .denied)
        await preference.refresh()

        // The row renders from `offer`, and this is the case that must not read as available.
        #expect(preference.offer == .blockedBySystem)

        await preference.setEnabled(true)
        // It did not silently "succeed" into a state where the switch sits on and nothing sends.
        #expect(preference.notifyEnabled == false)
        #expect(backend.events.isEmpty)
    }
}

// MARK: - The single re-offer

@MainActor
@Suite("Notification permission — the one re-offer")
struct NotificationReofferTests {

    @Test("\"Not now\" is re-offered exactly once and never again")
    func reofferedExactlyOnce() async {
        let (preference, authorizer, _) = makePreference()
        await preference.refresh()

        preference.declineSoftAsk()
        #expect(preference.shouldReofferAfterFirstEntry)

        preference.markReofferShown()
        #expect(preference.shouldReofferAfterFirstEntry == false)

        // A second entry, a tenth entry — the offer does not come back.
        preference.markReofferShown()
        #expect(preference.shouldReofferAfterFirstEntry == false)
        #expect(authorizer.promptCount == 0)
    }

    @Test("A parent who never deferred is never re-offered")
    func noReofferWithoutADeferral() async {
        let (preference, _, _) = makePreference()
        await preference.refresh()

        #expect(preference.shouldReofferAfterFirstEntry == false)
    }

    @Test("The deferral survives a relaunch")
    func deferralIsPersisted() async {
        let store = InMemoryNotificationAskStore()
        let authorizer = StubAuthorizer()
        let first = NotificationPreference(
            authorizer: authorizer, store: store, backend: StubPushBackend()
        )
        await first.refresh()
        first.declineSoftAsk()

        // A fresh instance reading the same store — which is what the next launch is.
        let second = NotificationPreference(
            authorizer: authorizer, store: store, backend: StubPushBackend()
        )
        await second.refresh()
        #expect(second.shouldReofferAfterFirstEntry)
    }
}

// MARK: - Enabling later, from iOS Settings

@MainActor
@Suite("Notification permission — enabled in iOS Settings later")
struct NotificationForegroundTests {

    @Test("Authorization granted outside the app registers a token and asks nothing")
    func laterAuthorizationRegistersSilently() async {
        let (preference, authorizer, backend) = makePreference(
            record: NotificationAskRecord(declinedSoftAsk: true)
        )
        await preference.refresh()
        #expect(backend.events.isEmpty)

        // The parent went to iOS Settings and switched notifications on.
        authorizer.set(status: .authorized)
        await preference.refresh()

        #expect(backend.events.contains("register"))
        // Nothing was asked. The prompt is not fired, and no soft ask is presented.
        #expect(authorizer.promptCount == 0)
        #expect(preference.offer == .alreadyAuthorized)
    }

    @Test("A foreground with permission still not determined registers nothing")
    func undeterminedRegistersNothing() async {
        let (preference, _, backend) = makePreference()
        await preference.refresh()
        #expect(backend.events.isEmpty)
    }
}

// MARK: - Writing the preference

@MainActor
@Suite("Notification preference writes")
struct NotificationWriteTests {

    @Test("The toggle writes through PATCH /v1/me and schedules nothing locally")
    func togglePatchesMe() async {
        let (preference, _, backend) = makePreference(status: .authorized)
        await preference.refresh()

        await preference.setEnabled(true)

        #expect(backend.events.contains("patch(enabled: true, time: -)"))
        // Nothing in this type reaches a scheduling API. The assertion the suite can make is
        // that every write is a PATCH and there is no other outbound call.
        #expect(backend.events.allSatisfy { $0 == "register" || $0.hasPrefix("patch") })
    }

    @Test("Changing the time sends only the time, never re-enabling a disabled preference")
    func timeWriteOmitsEnabled() async {
        let (preference, _, backend) = makePreference(status: .authorized)
        await preference.refresh()

        await preference.setTime(NotifyTime(hour: 7, minute: 15))

        #expect(backend.events.contains("patch(enabled: -, time: 07:15:00)"))
    }

    @Test("A failed write rolls the mirror back rather than leaving it showing on")
    func failedWriteRollsBack() async {
        let (preference, _, backend) = makePreference(status: .authorized)
        await preference.refresh()
        backend.failWrites()

        await preference.setEnabled(true)

        #expect(preference.notifyEnabled == false)
    }

    @Test("Sign-out revokes the device")
    func signOutRevokes() async {
        let (preference, _, backend) = makePreference(status: .authorized)
        await preference.revokeDevice()
        #expect(backend.events == ["revoke"])
    }
}
