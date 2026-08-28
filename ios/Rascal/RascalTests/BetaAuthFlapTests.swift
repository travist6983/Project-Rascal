import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Phase 132 — the beta auth flap, and the entry that said "Saving" and wasn't.
///
/// Two TestFlight reports the owner could not reproduce: an intermittent *"Can't reach the
/// archive"* that sometimes ended at the sign-in screen, and a several-hundred-word text entry
/// lost after the composer showed "Saving". The diagnosis is `docs/reports/phase-132-beta-auth-flap.md`.
///
/// **What these tests hold, in one sentence each:** a server having a bad minute is not a parent
/// signing out; a row is on disk before the UI claims anything; and an involuntary re-auth never
/// erases an archive.

// MARK: - B3 — a transport or server failure is not an auth failure

private func envelope(_ code: String, _ message: String = "no") -> Data {
    Data(#"{"error":{"code":"\#(code)","message":"\#(message)","field":null}}"#.utf8)
}

private func flapTokens() -> InMemoryTokenStore {
    InMemoryTokenStore(TokenPair(accessToken: "access", refreshToken: "refresh"))
}

private func flapClient(_ performer: HTTPPerforming, _ store: InMemoryTokenStore) -> APIClient {
    APIClient(baseURL: URL(string: "http://localhost:8000/")!, performer: performer, tokens: store)
}

/// Anything that answers a `/refresh` with this shape must leave the keychain alone.
private func refreshAnswers(
    _ body: Data,
    _ status: Int,
    file: String = #file
) async -> (store: InMemoryTokenStore, error: APIError?) {
    let performer = StubPerformer()
    performer.on("/today") { _ in (envelope("token_expired", "expired"), 401) }
    performer.on("/refresh") { _ in (body, status) }

    let store = flapTokens()
    let client = flapClient(performer, store)

    let error = await #expect(throws: APIError.self) {
        _ = try await client.sendRaw(.get, "v1/children/x/today")
    }
    return (store, error)
}

@Suite("Phase 132 — a server failure is not a sign-out")
struct RefreshFailureClassificationTests {

    /// **The defect this phase was opened for.**
    ///
    /// `api/fly.toml` accepts, in as many words, that a machine which cannot reach Postgres
    /// *"stays in the load balancer and answers 500s"*. The client turned that into a destroyed
    /// keychain: the parent saw "Can't reach the archive" over an already-empty session and the
    /// next launch put them on the sign-in screen, without a single 401 ever being returned.
    @Test(
        "a 5xx from refresh leaves the session alone",
        arguments: [500, 502, 503, 504]
    )
    func serverErrorKeepsTheSession(status: Int) async {
        let (store, error) = await refreshAnswers(envelope("internal_error", "bad minute"), status)

        #expect(store.load() != nil, "a server having a bad minute is not a parent signing out")
        #expect(store.load()?.refreshToken == "refresh", "and the pair is untouched, not rewritten")
        #expect(error != .sessionExpired, "the gate reads sessionExpired as signed-out")
    }

    /// 429 is the rate limiter, which is a request-shaped answer and says nothing about whether
    /// this refresh token is still good.
    @Test("a 429 from refresh leaves the session alone")
    func rateLimitedKeepsTheSession() async {
        let (store, error) = await refreshAnswers(envelope("rate_limited", "slow down"), 429)

        #expect(store.load() != nil)
        #expect(error?.code == .rateLimited)
    }

    /// The Fly edge during a rolling deploy of an app with `min_machines_running = 1`. The body is
    /// an HTML error page, so it never parses as the documented envelope — which is precisely the
    /// path that used to raise `.sessionExpired` and sign the parent out with no server verdict.
    @Test("an edge error page from refresh leaves the session alone and is not a sign-out")
    func nonEnvelopeServerErrorKeepsTheSession() async {
        let (store, error) = await refreshAnswers(Data("<html>502 Bad Gateway</html>".utf8), 502)

        #expect(store.load() != nil, "an HTML error page is not the server refusing a credential")
        #expect(error == .unexpectedStatus(502))
        #expect(error != .sessionExpired)
    }

    /// A code this build has never heard of is the one case where guessing wrong destroys an
    /// archive, so it resolves towards keeping the session.
    @Test("an unrecognised error code from refresh leaves the session alone")
    func unknownCodeKeepsTheSession() async {
        let (store, _) = await refreshAnswers(envelope("teapot_overheated"), 418)

        #expect(store.load() != nil)
    }

    /// The ladder still works. This is the regression guard on the fix: narrowing what may end a
    /// session must not stop a genuinely dead credential from ending one.
    @Test(
        "a real credential refusal still ends the session",
        arguments: ["unauthenticated", "token_expired", "refresh_token_reused"]
    )
    func credentialRefusalStillClears(code: String) async {
        let (store, _) = await refreshAnswers(envelope(code), 401)

        #expect(store.load() == nil, "the server said this token will never work again")
    }

    /// A 401 with no usable body is still an authentication answer, and the only status class
    /// where the absence of an envelope does not change the verdict.
    @Test("a bodiless 401 from refresh still ends the session")
    func bodilessUnauthorizedStillClears() async {
        let (store, _) = await refreshAnswers(Data(), 401)

        #expect(store.load() == nil)
    }

    /// Already true before this phase, asserted because it is half the rule and nothing pinned it.
    @Test("a transport failure during refresh leaves the session alone")
    func transportFailureKeepsTheSession() async {
        let performer = ThrowingRefreshPerformer()
        let store = flapTokens()
        let client = flapClient(performer, store)

        await #expect(throws: APIError.self) {
            _ = try await client.sendRaw(.get, "v1/children/x/today")
        }
        #expect(store.load() != nil, "offline is not signed out")
    }

    /// A 2xx whose body is not a token pair is a captive portal or a contract drift. It used to
    /// escape as a bare `DecodingError` past every `catch let error as APIError` between here and
    /// the gate, and the parent read a raw Swift decoding string under "Can't reach the archive".
    @Test("a 2xx from refresh that is not a token pair is a decoding fault, not a sign-out")
    func undecodableSuccessIsNotASignOut() async {
        let (store, error) = await refreshAnswers(Data(#"{"hello":"world"}"#.utf8), 200)

        #expect(store.load() != nil)
        if case .decoding = error {} else {
            Issue.record("expected .decoding, got \(String(describing: error))")
        }
    }

    /// The classifier itself, at the table level, so the rule is readable without a network.
    @Test("the credential-refusal rule, stated as a table")
    func classifierTable() {
        #expect(APIClient.refusesCredential(status: 401, code: .unauthenticated))
        #expect(APIClient.refusesCredential(status: 401, code: .tokenExpired))
        #expect(APIClient.refusesCredential(status: 401, code: .refreshTokenReused))
        #expect(APIClient.refusesCredential(status: 403, code: .notAuthorized))
        #expect(APIClient.refusesCredential(status: 401, code: nil))
        #expect(APIClient.refusesCredential(status: 403, code: nil))

        #expect(!APIClient.refusesCredential(status: 500, code: .internalError))
        #expect(!APIClient.refusesCredential(status: 503, code: .unknown("database_unreachable")))
        #expect(!APIClient.refusesCredential(status: 429, code: .rateLimited))
        #expect(!APIClient.refusesCredential(status: 422, code: .validationFailed))
        #expect(!APIClient.refusesCredential(status: 502, code: nil))
        #expect(!APIClient.refusesCredential(status: 503, code: nil))
        #expect(!APIClient.refusesCredential(status: 504, code: nil))
        #expect(!APIClient.refusesCredential(status: 418, code: .unknown("teapot")))
    }
}

/// Fails every request the way URLSession does — offline, DNS, TLS, a timeout.
private final class ThrowingRefreshPerformer: HTTPPerforming, @unchecked Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path().contains("refresh") == true {
            throw URLError(.timedOut)
        }
        return (
            envelope("token_expired", "expired"),
            HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        )
    }
}

// MARK: - B2 — a saved entry is on disk before the UI claims anything

@MainActor
@Suite("Phase 132 — the composer's commit is durable")
struct EntryCommitDurabilityTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Entry.self, Media.self, MediaPart.self, Assignment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// **The assertion the whole fix rests on**, and the reason it reads from a *second* context:
    /// an inserted-but-unsaved object lives in the context that inserted it and nowhere else. A
    /// fresh context on the same container sees a row only if `save()` actually ran.
    ///
    /// The lost entry was several hundred words of text with no photo, no video and no audio —
    /// one of the three completion shapes — so that is the shape asserted here.
    @Test("a text-only entry is readable from a fresh context, which means it reached the store")
    func textOnlyEntryIsDurable() throws {
        let container = try container()
        let childId = UUID()
        let entry = Entry(
            childId: childId,
            assignmentId: nil,
            occurredAt: Date(timeIntervalSince1970: 1_756_000_000),
            body: String(repeating: "the bedtime routine, step by step. ", count: 20),
            unlockAtAge: nil
        )
        let id = entry.id

        try EntryCache.commit(entry, in: ModelContext(container))

        let reader = ModelContext(container)
        let found = try reader.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id }))
        #expect(found.count == 1, "the row was never written to the store")
        #expect(found.first?.body?.isEmpty == false, "and it kept her words")
        #expect(found.first?.childId == childId)
    }

    /// The media path commits in the same breath as the entry, so a force quit between them is
    /// not a state that exists.
    @Test("an entry and its media land together")
    func entryAndMediaLandTogether() throws {
        let container = try container()
        let entry = Entry(childId: UUID(), assignmentId: nil, occurredAt: Date(), body: "with a photo", unlockAtAge: nil)
        let entryId = entry.id
        let media = Media(
            id: UUID(),
            entryId: entryId,
            kind: "photo",
            contentType: "image/jpeg",
            byteCount: 1024,
            stagedExtension: "jpg",
            capturedAt: nil,
            durationSeconds: nil
        )

        try EntryCache.commit(entry, media: [media], in: ModelContext(container))

        let reader = ModelContext(container)
        #expect(try reader.fetchCount(FetchDescriptor<Entry>(predicate: #Predicate { $0.id == entryId })) == 1)
        #expect(try reader.fetchCount(FetchDescriptor<Media>(predicate: #Predicate { $0.entryId == entryId })) == 1)
    }

    /// A did-it entry has no body and no media at all. Three completion shapes, and the commit
    /// path may not assume any of them carries an artefact.
    @Test("a did-it entry with no body and no media commits")
    func didItEntryIsDurable() throws {
        let container = try container()
        let entry = Entry(childId: UUID(), assignmentId: nil, occurredAt: Date(), body: nil, unlockAtAge: nil)
        let id = entry.id

        try EntryCache.commit(entry, in: ModelContext(container))

        let reader = ModelContext(container)
        #expect(try reader.fetchCount(FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })) == 1)
    }

    /// `occurredAt` is what the parent said happened; `createdAt` is when this phone wrote it
    /// down. Backdating is a first-class flow and the commit must not conflate them.
    @Test("commit preserves occurred_at and does not overwrite it with the write time")
    func commitKeepsOccurredAtDistinctFromCreatedAt() throws {
        let container = try container()
        let backdated = Date(timeIntervalSince1970: 1_500_000_000)
        let entry = Entry(childId: UUID(), assignmentId: nil, occurredAt: backdated, body: "in 2017", unlockAtAge: nil)
        let id = entry.id

        try EntryCache.commit(entry, in: ModelContext(container))

        let reader = ModelContext(container)
        let found = try #require(
            try reader.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })).first
        )
        #expect(found.occurredAt == backdated)
        #expect(found.createdAt != backdated, "createdAt is when this phone wrote it, not when it happened")
    }
}

// MARK: - B1 — an involuntary re-authentication never erases an archive

/// Counts erasures. The app wires the real one in `OnboardingSession.live()` and nowhere else.
@MainActor
final class SpyArchiveErasure: LocalArchiveErasing {
    private(set) var eraseCount = 0
    func erase() { eraseCount += 1 }
}

@MainActor
@Suite("Phase 132 — only a deliberate sign-out erases")
struct InvoluntaryReauthDoesNotEraseTests {

    /// The path the working hypothesis was built on. It does not erase, and this is the test that
    /// says so rather than a doc comment.
    @Test("a refresh the server rejects ends the session and erases nothing")
    func rejectedRefreshErasesNothing() async {
        let spy = SpyArchiveErasure()
        let performer = StubPerformer()
        performer.on("/children") { _ in (unauthenticatedEnvelope(), 401) }
        performer.on("/auth/refresh") { _ in (unauthenticatedEnvelope(), 401) }

        let session = onboardingSession(performer, tokens: signedIn, localArchive: spy)
        await session.resume()

        #expect(session.state == .signedOut, "the session did end")
        #expect(spy.eraseCount == 0, "and it took none of the child's archive with it")
    }

    /// Apple reporting a revoked credential is not a decision the parent made in this app.
    @Test("a revoked Apple credential ends the session and erases nothing")
    func revokedCredentialErasesNothing() async {
        let spy = SpyArchiveErasure()
        let appleIDs = InMemoryAppleUserIDStore()
        appleIDs.save("apple-subject")

        let session = onboardingSession(
            StubPerformer(),
            tokens: signedIn,
            appleIDs: appleIDs,
            credentials: StubCredentialCheck(.revoked),
            localArchive: spy
        )
        await session.resume()

        #expect(session.state == .signedOut)
        #expect(spy.eraseCount == 0)
    }

    /// A launch that cannot reach the server keeps everything, including the session.
    @Test("a launch that cannot reach the server erases nothing and keeps the session")
    func unreachableServerErasesNothing() async {
        let spy = SpyArchiveErasure()
        let performer = StubPerformer()
        performer.on("/children") { _ in (Data("{}".utf8), 500) }

        let session = onboardingSession(performer, tokens: signedIn, localArchive: spy)
        await session.resume()

        #expect(session.state == .loading)
        #expect(session.resolveFailed, "and offers a retry rather than a sign-in screen")
        #expect(spy.eraseCount == 0)
    }

    /// **The path every earlier reading declared unreachable, and it was not.**
    ///
    /// `completeEmailSignIn` refuses to move an active session to another account — a real and
    /// necessary guard. It used to enforce that by running the *erasing* sign-out, so a stranger
    /// who knew a parent's address could mail a link for their own account and delete every
    /// unsynced entry on that phone from the outside. A security guard has no business also being
    /// an irreversible delete.
    @Test("a sign-in link for a different account signs out and erases nothing")
    func foreignSignInLinkErasesNothing() async {
        let spy = SpyArchiveErasure()
        let mine = UUID()
        let theirs = UUID()
        let performer = StubPerformer()
        performer.on("/auth/email/complete") { _ in (sessionJSON(userId: theirs), 200) }

        let session = onboardingSession(
            performer,
            tokens: signedIn,
            record: InMemoryUserRecordStore(flapUser(id: mine)),
            localArchive: spy
        )
        await session.completeEmailSignIn(token: "a-link-that-is-not-hers")

        #expect(session.state == .signedOut, "it must still refuse to swap the session")
        #expect(session.notice != nil, "and say why")
        #expect(spy.eraseCount == 0, "but it may not delete the archive it was protecting")
    }

    /// **The ghost identity that made the path above reachable at all.**
    ///
    /// `AppSession.init` rehydrates `user` from the stored record on every cold launch, so an
    /// involuntarily-ended session used to leave `account.user?.id` answering for an account that
    /// was no longer signed in — which is exactly the value the magic-link guard compares against.
    @Test("an involuntary sign-out leaves no user record behind for the next launch to rehydrate")
    func involuntarySignOutClearsTheUserRecord() async {
        let record = InMemoryUserRecordStore(flapUser(id: UUID()))
        let performer = StubPerformer()
        performer.on("/children") { _ in (unauthenticatedEnvelope(), 401) }
        performer.on("/auth/refresh") { _ in (unauthenticatedEnvelope(), 401) }

        let session = onboardingSession(performer, tokens: signedIn, record: record)
        await session.resume()

        #expect(session.state == .signedOut)
        #expect(record.load() == nil, "a dead session left an identity for a magic link to compare against")
        #expect(session.account.user == nil)
    }

    /// The other involuntary path to the same ghost: `APIClient` dropped the pair itself and this
    /// launch is the first thing to notice.
    @Test("a launch that finds no session clears the user record too")
    func noSessionLaunchClearsTheUserRecord() async {
        let record = InMemoryUserRecordStore(flapUser(id: UUID()))

        let session = onboardingSession(StubPerformer(), tokens: nil, record: record)
        await session.resume()

        #expect(session.state == .signedOut)
        #expect(record.load() == nil)
    }

    /// The other half of the rule. A deliberate tap must still erase, or a phone handed on carries
    /// a child's thumbnails, transcripts and staged files to its next owner.
    @Test("a deliberate Sign out does erase")
    func deliberateSignOutErases() async {
        let spy = SpyArchiveErasure()
        let session = onboardingSession(StubPerformer(), tokens: signedIn, localArchive: spy)

        await session.signOut()

        #expect(session.state == .signedOut)
        #expect(spy.eraseCount == 1)
    }
}

// MARK: - B4 — which build is this?

@Suite("Phase 132 — every request says which build sent it")
struct ClientBuildHeaderTests {

    @Test("an authenticated request carries the build header")
    func authenticatedRequestCarriesTheHeader() async throws {
        let performer = StubPerformer()
        performer.on("/today") { _ in (Data("{}".utf8), 200) }

        let client = flapClient(performer, flapTokens())
        _ = try await client.sendRaw(.get, "v1/children/x/today")

        let sent = try #require(performer.requests.first)
        #expect(sent.value(forHTTPHeaderField: APIClient.buildHeader) == APIClient.buildIdentifier)
    }

    /// The one request whose failures started this phase. A log line that cannot say which build
    /// sent a refresh is the log line this was built for.
    @Test("the refresh request carries the build header too")
    func refreshCarriesTheHeader() async {
        let performer = StubPerformer()
        performer.on("/today") { _ in (envelope("token_expired", "expired"), 401) }
        performer.on("/refresh") { _ in (envelope("unauthenticated"), 401) }

        let client = flapClient(performer, flapTokens())
        _ = try? await client.sendRaw(.get, "v1/children/x/today")

        let refresh = performer.requests.first { $0.url?.path().contains("refresh") == true }
        #expect(refresh?.value(forHTTPHeaderField: APIClient.buildHeader) == APIClient.buildIdentifier)
    }

    /// It has to be readable by a person scanning a log, and it has to name the platform — the
    /// same version numbers will exist on other clients one day.
    @Test("the identifier names the platform and is never empty")
    func identifierIsUsable() {
        #expect(APIClient.buildIdentifier.hasPrefix("ios/"))
        #expect(APIClient.buildIdentifier.count > "ios/".count)
        #expect(APIClient.buildHeader == "X-Client-Build")
    }

    /// A caller-supplied header wins, so `Idempotency-Key` and friends are unaffected by the
    /// default being set first.
    @Test("a caller-supplied header still overrides the default")
    func callerHeadersWin() async throws {
        let performer = StubPerformer()
        performer.on("/entries") { _ in (Data("{}".utf8), 200) }

        let client = flapClient(performer, flapTokens())
        _ = try await client.sendRaw(.post, "v1/entries", headers: [APIClient.buildHeader: "override"])

        #expect(performer.requests.first?.value(forHTTPHeaderField: APIClient.buildHeader) == "override")
    }
}

// MARK: - The keychain write, which used to fail silently

@Suite("Phase 132 — a keychain write that does not land is not a success")
struct TokenStoreWriteTests {

    /// Rotation is destructive server-side: the presented token is revoked *before* the
    /// replacement is issued. So a write that silently no-ops leaves this phone holding a dead
    /// token, and the next launch presents it, takes `refresh_token_reused`, and has every other
    /// session on the account revoked with it. Dropping the stale pair costs one sign-in here and
    /// costs the parent's other devices nothing.
    @Test("a refresh whose keychain write fails does not leave a revoked token behind")
    func failedWriteDoesNotStrandARevokedToken() async {
        let performer = StubPerformer()
        // **The retry must succeed, and that is not incidental.** A `/today` that 401s twice takes
        // `sendRaw`'s retry-exhausted `tokens.clear()` instead, and the test then passes against a
        // client that ignores the write failure entirely — which is exactly what it did until the
        // break-test caught it.
        performer.on("/today") { n in
            n == 1 ? (envelope("token_expired", "expired"), 401) : (Data("{}".utf8), 200)
        }
        performer.on("/refresh") { _ in
            (Data(#"{"access_token":"a2","refresh_token":"r2","token_type":"bearer","expires_in":900}"#.utf8), 200)
        }

        let store = RefusingTokenStore(TokenPair(accessToken: "a1", refreshToken: "r1"))
        let client = APIClient(baseURL: URL(string: "http://localhost:8000/")!, performer: performer, tokens: store)

        _ = try? await client.sendRaw(.get, "v1/children/x/today")

        #expect(performer.count(for: "today") == 2, "the ladder must not be what emptied the store")
        #expect(store.load() == nil, "r1 is revoked server-side; presenting it revokes the whole chain")
    }

    /// The seam only works if a real store answers honestly on the happy path too.
    @Test("a write that lands reports that it landed")
    func successfulWriteReportsTrue() {
        let store = InMemoryTokenStore()
        #expect(store.save(TokenPair(accessToken: "a", refreshToken: "r")))
        #expect(store.load()?.refreshToken == "r")
    }
}

/// A keychain that accepts reads and silently refuses writes — `errSecInteractionNotAllowed`
/// before first unlock, a `-34018` daemon fault, an `errSecDuplicateItem`. The class of failure
/// `KeychainTokenStore.save` used to discard.
private final class RefusingTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pair: TokenPair?

    init(_ pair: TokenPair?) { self.pair = pair }

    func load() -> TokenPair? {
        lock.lock(); defer { lock.unlock() }
        return pair
    }

    func save(_ pair: TokenPair) -> Bool { false }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pair = nil
    }
}

// MARK: - Fixtures

func flapUser(id: UUID) -> UserResponse {
    UserResponse(
        id: id,
        email: "parent@example.com",
        displayName: "Ada",
        isAdmin: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

func sessionJSON(userId: UUID) -> Data {
    Data("""
    {"access_token":"a","refresh_token":"r","token_type":"bearer","expires_in":900,
     "user":{"id":"\(userId.uuidString)","email":"other@example.com","display_name":"Someone Else",
             "is_admin":false,"created_at":"2026-08-01T00:00:00.000Z",
             "notify_enabled":false,"notify_local_time":"19:30"}}
    """.utf8)
}
