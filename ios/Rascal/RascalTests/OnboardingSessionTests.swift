import Foundation
import Testing

@testable import Rascal

/// The gate's state machine, and the four steps behind it.
@MainActor
@Suite("Onboarding — session and setup")
struct OnboardingSessionTests {

    // MARK: Resolving a launch

    @Test("no stored session resolves to signedOut, and asks the server nothing")
    func coldLaunchIsSignedOut() async throws {
        let performer = StubPerformer()
        let session = onboardingSession(performer, tokens: nil)
        await session.resume()

        #expect(session.state == .signedOut)
        #expect(performer.requests.isEmpty, "there is no session to ask about")
    }

    @Test("a stored session with a child goes straight to ready")
    func warmLaunchWithAChildIsReady() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/children") { _ in (meChildrenJSON(child), 200) }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()

        #expect(session.state.readyChild?.id == child)
        #expect(session.state.readyChild?.familyTimezone == "America/Detroit")
    }

    @Test("a stored session with no children needs one")
    func warmLaunchWithoutAChildNeedsOne() async throws {
        let performer = StubPerformer()
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()

        #expect(session.state == .needsChild)
        #expect(session.draft.step == .name, "and setup starts at the beginning")
    }

    @Test("an expired session that cannot refresh resolves to signedOut")
    func expiredSessionSignsOut() async throws {
        let performer = StubPerformer()
        performer.on("/children") { _ in (unauthenticatedEnvelope(), 401) }
        performer.on("/auth/refresh") { _ in (unauthenticatedEnvelope(), 401) }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()

        #expect(session.state == .signedOut)
    }

    /// A token we hold plus a server we cannot reach is **not** a signed-out parent. Dumping
    /// someone onto a sign-in screen they have no connection to complete would be the worse bug.
    @Test("no connection keeps the session and offers a retry")
    func offlineLaunchOffersARetry() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/children") { n in
            n == 1 ? (Data("{}".utf8), 500) : (meChildrenJSON(child), 200)
        }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()

        #expect(session.state == .loading)
        #expect(session.resolveFailed)
        #expect(session.notice != nil)

        // The retry is the same call, and it lands.
        await session.resume()
        #expect(session.state.readyChild?.id == child)
        #expect(session.resolveFailed == false)
    }

    // MARK: The returning user

    @Test("a returning account with a child skips child creation entirely")
    func returningUserSkipsSetup() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/auth/apple") { _ in (onboardingSessionJSON(displayName: "Ada"), 200) }
        performer.on("/children") { _ in (meChildrenJSON(child), 200) }

        let session = onboardingSession(performer)
        await session.signIn(with: appleCredential(fullName: nil))

        #expect(session.state.readyChild?.id == child)
        #expect(
            performer.count(forPathContaining: "/children", method: "POST") == 0,
            "an existing child is never re-created"
        )
    }

    @Test("more than one child takes the first and builds no picker")
    func multipleChildrenTakesTheFirst() async throws {
        let first = UUID()
        let second = UUID()
        let performer = StubPerformer()
        performer.on("/children") { _ in (twoChildrenJSON(first, second), 200) }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()

        #expect(session.state.readyChild?.id == first)
    }

    // MARK: Creating the child

    @Test("a successful setup sends name, birthdate and IANA timezone, and lands on ready")
    func createSendsTheRightBody() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/children") { n in
            n == 1 ? (Data("[]".utf8), 200) : (oneChildJSON(child, name: "Milo"), 201)
        }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()
        session.draft.name = "  Milo  "
        session.draft.birthdate = "2022-06-12"
        session.draft.timezone = "America/Detroit"
        await session.createChild()

        let body = try #require(performer.body(forPathContaining: "/children"))
        #expect(body["name"] as? String == "Milo", "trimmed")
        #expect(body["birthdate"] as? String == "2022-06-12", "a calendar day, not a timestamp")
        #expect(body["family_timezone"] as? String == "America/Detroit")
        #expect(session.state.readyChild?.id == child)
    }

    /// **The duplicate-child case.** `POST /children` has no `Idempotency-Key`, so a create whose
    /// *response* was lost has still created a child. A blind retry would make a second one that
    /// the product cannot show or remove.
    @Test("a create whose response was lost adopts the child instead of making a second")
    func lostResponseDoesNotDuplicate() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/children") { n in
            switch n {
            case 1: (Data("[]".utf8), 200)                       // GET at resume — nothing yet
            case 2: (Data("{}".utf8), 500)                       // POST — the row is written, the answer is not
            default: (childListJSON(child, name: "Milo"), 200)   // GET by the guard — a *list*, there it is
            }
        }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()
        session.draft.name = "Milo"
        session.draft.birthdate = "2022-06-12"
        await session.createChild()

        #expect(session.state.readyChild?.id == child, "the child that already exists is adopted")
        #expect(
            performer.count(forPathContaining: "/children", method: "POST") == 1,
            "exactly one create was ever attempted"
        )
        // The assumption the case numbers above encode, asserted rather than trusted.
        #expect(performer.methods(forPathContaining: "/children") == ["GET", "POST", "GET"])
    }

    @Test("a create that genuinely failed, then retried, produces exactly one child")
    func failedCreateThenRetryMakesOne() async throws {
        let child = UUID()
        let created = HitCounter()
        let performer = StubPerformer()
        performer.on("/children") { n in
            switch n {
            case 1, 3:
                return (Data("[]".utf8), 200)   // GET at resume, then the guard — still nothing
            case 2:
                return (Data("{}".utf8), 500)   // POST — genuinely refused, nothing written
            default:                            // POST retry — this one lands
                created.increment()
                return (oneChildJSON(child, name: "Milo"), 201)
            }
        }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()
        session.draft.name = "Milo"
        session.draft.birthdate = "2022-06-12"

        await session.createChild()
        #expect(session.state == .needsChild, "nothing was created, so setup stays put")
        #expect(session.notice != nil, "and says so, with a retry")

        await session.createChild()

        #expect(session.state.readyChild?.id == child)
        #expect(created.value == 1, "one child on the server, not two")
        #expect(performer.methods(forPathContaining: "/children") == ["GET", "POST", "GET", "POST"])
    }

    @Test("a create in flight cannot be started twice by a double tap")
    func doubleTapCannotCreateTwice() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.delay = .milliseconds(60)
        performer.on("/children") { n in
            n == 1 ? (Data("[]".utf8), 200) : (oneChildJSON(child, name: "Milo"), 201)
        }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()
        session.draft.name = "Milo"
        session.draft.birthdate = "2022-06-12"

        async let first: Void = session.createChild()
        async let second: Void = session.createChild()
        _ = await (first, second)

        #expect(performer.count(forPathContaining: "/children", method: "POST") == 1)
        #expect(session.state.readyChild?.id == child)
    }

    @Test("setup will not submit without a name and a birthdate")
    func incompleteDraftIsNotSubmitted() async throws {
        let performer = StubPerformer()
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()
        session.draft.name = "   "
        await session.createChild()

        #expect(performer.count(forPathContaining: "/children", method: "POST") == 0)
        #expect(session.state == .needsChild)
    }

    // MARK: Steps and resumability

    @Test("the steps walk forwards and backwards and stop at both ends")
    func stepsWalkAndStop() async throws {
        let session = onboardingSession(StubPerformer(), tokens: nil)

        #expect(session.draft.step == .name)
        session.goBack()
        #expect(session.draft.step == .name, "there is nothing before the first step")

        session.advance()
        #expect(session.draft.step == .birthdate)
        session.advance()
        #expect(session.draft.step == .timezone)
        session.advance()
        #expect(session.draft.step == .avatar)
        session.advance()
        #expect(session.draft.step == .avatar, "and nothing after the last")

        session.goBack()
        #expect(session.draft.step == .timezone)
    }

    @Test("a kill mid-setup resumes on the same step with the same input")
    func draftSurvivesARelaunch() async throws {
        let drafts = InMemoryOnboardingDraftStore()
        let performer = StubPerformer()
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let first = onboardingSession(performer, tokens: signedIn, drafts: drafts)
        await first.resume()
        first.draft.name = "Milo"
        first.draft.birthdate = "2022-06-12"
        first.draft.timezone = "Europe/Lisbon"
        first.advance()
        first.advance()

        // Killed here. A new process, the same store.
        let relaunched = onboardingSession(performer, tokens: signedIn, drafts: drafts)
        await relaunched.resume()

        #expect(relaunched.state == .needsChild)
        #expect(relaunched.draft.step == .timezone)
        #expect(relaunched.draft.name == "Milo")
        #expect(relaunched.draft.birthdate == "2022-06-12")
        #expect(relaunched.draft.timezone == "Europe/Lisbon")
    }

    @Test("the draft is cleared once the child exists")
    func draftIsClearedOnCompletion() async throws {
        let drafts = InMemoryOnboardingDraftStore()
        let performer = StubPerformer()
        performer.on("/children") { n in
            n == 1 ? (Data("[]".utf8), 200) : (oneChildJSON(UUID(), name: "Milo"), 201)
        }

        let session = onboardingSession(performer, tokens: signedIn, drafts: drafts)
        await session.resume()
        session.draft.name = "Milo"
        session.draft.birthdate = "2022-06-12"
        session.persist()
        #expect(drafts.load() != nil)

        await session.createChild()

        #expect(drafts.load() == nil, "the server's copy is the truth now")
    }

    @Test("a draft that cannot be decoded is treated as absent")
    func corruptDraftIsIgnored() throws {
        let suite = "onboarding-draft-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not a draft".utf8), forKey: "onboarding.draft")
        #expect(UserDefaultsOnboardingDraftStore(defaults: defaults).load() == nil)
    }

    // MARK: Timezone

    /// The scheduler's entire definition of "today" is this string. An abbreviation or an offset
    /// would be accepted by nothing and would silently mean the wrong day.
    @Test("the default timezone is a resolvable IANA identifier, never an abbreviation or offset")
    func defaultTimezoneIsIANA() {
        let identifier = OnboardingDraft().timezone

        #expect(identifier == TimeZone.current.identifier)
        #expect(TimeZone(identifier: identifier) != nil, "zoneinfo knows it")
        #expect(TimeZone.knownTimeZoneIdentifiers.contains(identifier))
        #expect(identifier.hasPrefix("GMT") == false)
        #expect(identifier.contains("+") == false && identifier.contains("-") == false)
        // "EDT" and friends are three or four letters with no region. Every IANA zone that is
        // not one of the handful of legacy singletons carries a region and a slash.
        #expect(identifier.count > 4)
    }

    @Test("the timezone chosen during setup is the one that is sent")
    func chosenTimezoneIsSent() async throws {
        let performer = StubPerformer()
        performer.on("/children") { n in
            n == 1 ? (Data("[]".utf8), 200) : (oneChildJSON(UUID(), name: "Milo"), 201)
        }

        let session = onboardingSession(performer, tokens: signedIn)
        await session.resume()
        session.draft.name = "Milo"
        session.draft.birthdate = "2022-06-12"
        session.draft.timezone = "Pacific/Auckland"
        await session.createChild()

        let body = try #require(performer.body(forPathContaining: "/children"))
        #expect(body["family_timezone"] as? String == "Pacific/Auckland")
    }

    // MARK: Birthdate

    @Test("a birthdate in the future is refused, quietly")
    func futureBirthdateIsRefused() {
        let now = Date(timeIntervalSince1970: 1_786_300_000)
        let tomorrow = now.addingTimeInterval(60 * 60 * 24)

        #expect(BirthdateRule.check(tomorrow, now: now) == .inTheFuture)
        #expect(BirthdateRule.check(tomorrow, now: now).message != nil)
        // Copy rules: it says what is wrong and what to do, and it does not scold.
        #expect(BirthdateRule.check(tomorrow, now: now).message?.contains("year") == true)
    }

    @Test("today is not in the future, at any hour of it")
    func todayIsAcceptable() {
        let now = Date(timeIntervalSince1970: 1_786_300_000)
        // A birthdate is a calendar day. Comparing instants would refuse a baby born this
        // morning for the rest of the day.
        let earlierToday = Calendar.current.startOfDay(for: now)

        #expect(BirthdateRule.check(earlierToday, now: now) == .ok)
        #expect(BirthdateRule.check(now, now: now) == .ok)
    }

    /// Both dates are built in the *current* calendar, so the arithmetic holds whatever zone the
    /// machine running this is in.
    @Test("the age echo counts whole months, and says them the way Entry Detail does")
    func ageEchoComputesAndReads() throws {
        let calendar = Calendar.current
        let born = try #require(calendar.date(from: DateComponents(year: 2022, month: 6, day: 12)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 9)))

        #expect(DraftAge.months(from: born, to: now) == 49)
        #expect(AgeText.long(49) == "4 years, 1 month")
        #expect(DraftAge.label(from: born, to: now) == "4 years, 1 month")
        #expect(DraftAge.spoken(from: born, to: now) == "4 years 1 month old")
    }

    @Test("a birthday today reads as newborn rather than as a negative number")
    func newbornReadsAsNewborn() {
        let now = Date(timeIntervalSince1970: 1_786_300_000)
        #expect(DraftAge.months(from: now, to: now) == 0)
        #expect(DraftAge.label(from: now, to: now) == "Newborn")
    }

    @Test("a future birthdate cannot produce a negative age")
    func futureBirthdateClampsTheEcho() {
        let now = Date(timeIntervalSince1970: 1_786_300_000)
        let ahead = now.addingTimeInterval(60 * 60 * 24 * 400)
        #expect(DraftAge.months(from: ahead, to: now) == 0)
    }

    @Test("a name is trimmed, required, and capped at what the server accepts")
    func nameValidation() {
        var draft = OnboardingDraft()
        #expect(draft.isNameValid == false)

        draft.name = "   "
        #expect(draft.isNameValid == false)

        draft.name = "  Milo "
        #expect(draft.isNameValid)
        #expect(draft.trimmedName == "Milo")

        draft.name = String(repeating: "a", count: OnboardingDraft.nameLimit)
        #expect(draft.isNameValid)
        draft.name = String(repeating: "a", count: OnboardingDraft.nameLimit + 1)
        #expect(draft.isNameValid == false)
    }

    // MARK: Avatar

    @Test("an avatar is stored against the child that setup created")
    func avatarIsStoredAgainstTheChild() async throws {
        let child = UUID()
        let avatars = InMemoryAvatarStore()
        let performer = StubPerformer()
        performer.on("/children") { n in
            n == 1 ? (Data("[]".utf8), 200) : (oneChildJSON(child, name: "Milo"), 201)
        }

        let session = onboardingSession(performer, tokens: signedIn, avatars: avatars)
        await session.resume()
        session.draft.name = "Milo"
        session.draft.birthdate = "2022-06-12"
        session.avatar = Data("jpeg-bytes".utf8)
        await session.createChild()

        #expect(avatars.load(for: child) == Data("jpeg-bytes".utf8))
    }

    /// A skipped avatar is a complete onboarding, not a deficient one.
    @Test("skipping the avatar still finishes setup")
    func skippingTheAvatarFinishes() async throws {
        let child = UUID()
        let avatars = InMemoryAvatarStore()
        let performer = StubPerformer()
        performer.on("/children") { n in
            n == 1 ? (Data("[]".utf8), 200) : (oneChildJSON(child, name: "Milo"), 201)
        }

        let session = onboardingSession(performer, tokens: signedIn, avatars: avatars)
        await session.resume()
        session.draft.name = "Milo"
        session.draft.birthdate = "2022-06-12"
        await session.createChild()

        #expect(session.state.readyChild?.id == child)
        #expect(avatars.load(for: child) == nil)
    }

    // MARK: The whole flow

    /// First run, end to end, at the level the logic actually lives: no session, Apple, four
    /// steps, one create, Today. The project has no XCUITest target — see the phase report.
    @Test("first run walks sign-in, the four steps, and one create, and lands on ready")
    func firstRunEndToEnd() async throws {
        let child = UUID()
        let drafts = InMemoryOnboardingDraftStore()
        let performer = StubPerformer()
        performer.on("/auth/apple") { _ in (onboardingSessionJSON(displayName: "Ada Lovelace"), 200) }
        performer.on("/children") { n in
            n == 1 ? (Data("[]".utf8), 200) : (oneChildJSON(child, name: "Milo"), 201)
        }

        let session = onboardingSession(performer, tokens: nil, drafts: drafts)

        await session.resume()
        #expect(session.state == .signedOut)

        await session.signIn(with: appleCredential(fullName: "Ada Lovelace"))
        #expect(session.state == .needsChild)
        #expect(session.draft.step == .name)

        session.draft.name = "Milo"
        session.persist()
        session.advance()
        #expect(session.draft.step == .birthdate)

        session.draft.birthdate = "2022-06-12"
        session.persist()
        session.advance()
        #expect(session.draft.step == .timezone)

        session.draft.timezone = "America/Detroit"
        session.persist()
        session.advance()
        #expect(session.draft.step == .avatar)

        await session.createChild()

        #expect(session.state.readyChild?.id == child)
        #expect(session.state.readyChild?.name == "Milo")
        #expect(drafts.load() == nil)
        #expect(performer.count(forPathContaining: "/children", method: "POST") == 1)
        #expect(session.account.user?.displayName == "Ada Lovelace")
    }
}

// MARK: - Fixtures

/// A token pair standing for "this device has signed in before".
let signedIn = TokenPair(accessToken: "access", refreshToken: "refresh")

@MainActor
func onboardingSession(
    _ performer: StubPerformer,
    tokens: TokenPair? = nil,
    record: UserRecordStoring = InMemoryUserRecordStore(),
    drafts: OnboardingDraftStoring = InMemoryOnboardingDraftStore(),
    appleIDs: AppleUserIDStoring = InMemoryAppleUserIDStore(),
    credentials: AppleCredentialChecking = StubCredentialCheck(.authorized),
    avatars: AvatarStoring = InMemoryAvatarStore()
) -> OnboardingSession {
    let store = InMemoryTokenStore(tokens)
    let account = AppSession(
        api: APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: store
        ),
        tokens: store,
        record: record
    )
    return OnboardingSession(
        account: account,
        drafts: drafts,
        appleIDs: appleIDs,
        credentials: credentials,
        avatars: avatars
    )
}

func unauthenticatedEnvelope() -> Data {
    Data(#"{"error":{"code":"unauthenticated","message":"Sign in again."}}"#.utf8)
}

/// `GET /children` answers with a **list**; `POST /children` answers with a bare object. Getting
/// these the wrong way round is exactly what the duplicate-child guard fails silently on, because
/// its lookup is a `try?` — so the two shapes have separate fixtures rather than one shared one.
func childListJSON(_ id: UUID, name: String) -> Data {
    var list = Data("[".utf8)
    list.append(oneChildJSON(id, name: name))
    list.append(Data("]".utf8))
    return list
}

/// `ChildWithRole` — the single-object form, which is what `POST /children` returns.
func oneChildJSON(_ id: UUID, name: String) -> Data {
    Data("""
    {"id":"\(id.uuidString)","name":"\(name)","birthdate":"2022-06-12",
     "family_timezone":"America/Detroit","age_months":49,"role":"parent"}
    """.utf8)
}

func twoChildrenJSON(_ first: UUID, _ second: UUID) -> Data {
    Data("""
    [{"id":"\(first.uuidString)","name":"Milo","birthdate":"2022-06-12",
      "family_timezone":"America/Detroit","age_months":49,"role":"parent"},
     {"id":"\(second.uuidString)","name":"Ada","birthdate":"2024-01-02",
      "family_timezone":"America/Detroit","age_months":31,"role":"parent"}]
    """.utf8)
}

/// A `@Sendable`-safe tally, for counting what the stub actually created.
nonisolated final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

extension StubPerformer {
    /// The HTTP methods seen on a path, in order. Lets a test assert the sequence it assumed
    /// when it keyed responses off a hit count.
    func methods(forPathContaining path: String) -> [String] {
        requests
            .filter { $0.url?.path().contains(path) ?? false }
            .compactMap(\.httpMethod)
    }
}
