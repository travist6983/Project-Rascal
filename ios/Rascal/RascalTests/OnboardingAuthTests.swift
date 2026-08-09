import Foundation
import Testing

@testable import Rascal

/// Sign in with Apple, and the one field that is unrecoverable if this client gets it wrong.
///
/// Apple populates `fullName` on the **first authorization for a given Apple ID, ever** — not the
/// first per install, and deleting the app does not reset it. Everything in this suite exists
/// because there is no second chance to get the name onto the server.
@MainActor
@Suite("Onboarding — Sign in with Apple")
struct OnboardingAuthTests {

    // MARK: display_name on the wire

    @Test("a credential carrying a name sends display_name")
    func nameIsForwarded() async throws {
        let performer = StubPerformer()
        performer.on("/auth/apple") { _ in (onboardingSessionJSON(displayName: "Ada Lovelace"), 200) }
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let session = onboardingSession(performer)
        await session.signIn(with: appleCredential(fullName: "Ada Lovelace"))

        let body = try #require(performer.body(forPathContaining: "/auth/apple"))
        #expect(body["display_name"] as? String == "Ada Lovelace")
        #expect(body["identity_token"] as? String == "identity-token")
    }

    /// **The key assertion in this file.**
    ///
    /// Absent, not null and not `""`. The server applies first-write-wins to `display_name` and
    /// leaves the stored value alone when the field is missing; an empty string is a *value* and
    /// would win that race and permanently occupy the column with nothing.
    @Test("a credential with no name omits the key entirely — no null, no empty string")
    func absentNameOmitsTheKey() async throws {
        let performer = StubPerformer()
        performer.on("/auth/apple") { _ in (onboardingSessionJSON(displayName: "Ada Lovelace"), 200) }
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let session = onboardingSession(performer)
        await session.signIn(with: appleCredential(fullName: nil))

        let body = try #require(performer.body(forPathContaining: "/auth/apple"))
        #expect(body["display_name"] == nil, "the key must be absent, not present-and-null")
        #expect(body.keys.contains("display_name") == false)

        // Belt and braces: the raw bytes must not mention it either. A JSON null decodes to
        // NSNull rather than nil through JSONSerialization, and this catches that reading.
        let raw = try #require(performer.rawBody(forPathContaining: "/auth/apple"))
        #expect(String(decoding: raw, as: UTF8.self).contains("display_name") == false)
    }

    @Test("an all-empty PersonNameComponents becomes nil rather than a blank name")
    func blankComponentsAreNotAName() {
        // Apple hands back a non-nil `fullName` even when the parent shared nothing, and
        // formatting that yields "". Turning it into nil here is what keeps `""` off the wire.
        #expect(AppleCredentialInput.name(from: PersonNameComponents()) == nil)

        var spaces = PersonNameComponents()
        spaces.givenName = "   "
        #expect(AppleCredentialInput.name(from: spaces) == nil)

        var real = PersonNameComponents()
        real.givenName = "Ada"
        real.familyName = "Lovelace"
        #expect(AppleCredentialInput.name(from: real) == "Ada Lovelace")
    }

    // MARK: The held payload

    /// A failed exchange must retry the *same bytes*. Re-prompting Apple returns
    /// `fullName: nil`, so "just ask again" is precisely how the name is lost forever.
    @Test("a failed exchange retries the identical payload, name included")
    func retryReusesTheExactPayload() async throws {
        let performer = StubPerformer()
        performer.on("/auth/apple") { n in
            n == 1
                ? (Data(#"{"error":{"code":"internal_error","message":"nope"}}"#.utf8), 500)
                : (onboardingSessionJSON(displayName: "Ada Lovelace"), 200)
        }
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let session = onboardingSession(performer)
        await session.resume()
        #expect(session.state == .signedOut)

        await session.signIn(with: appleCredential(fullName: "Ada Lovelace"))

        #expect(session.pendingExchange != nil, "a failed exchange is held, not discarded")
        #expect(session.state == .signedOut, "and the parent is left on the screen they were on")
        #expect(session.notice != nil)

        let held = try #require(session.pendingExchange)
        await session.retryExchange()

        // Compared field by field rather than byte for byte: `JSONEncoder` makes no promise
        // about key *order*, so two encodings of the same values can differ as bytes. What has
        // to hold is that the second request carries the same values as the first — above all
        // the name, which Apple will not send again.
        let bodies = performer.bodies(forPathContaining: "/auth/apple")
        #expect(bodies.count == 2)
        #expect(Set(bodies[0].keys) == Set(bodies[1].keys), "the same keys, both times")
        #expect(bodies[0]["identity_token"] as? String == bodies[1]["identity_token"] as? String)
        #expect(bodies[0]["display_name"] as? String == bodies[1]["display_name"] as? String)
        #expect(bodies[0]["authorization_code"] as? String == bodies[1]["authorization_code"] as? String)
        #expect(bodies[1]["display_name"] as? String == "Ada Lovelace")
        #expect(held.displayName == "Ada Lovelace", "the retried payload is the held one")

        #expect(session.pendingExchange == nil, "and it is released once it lands")
        #expect(session.state == .needsChild)
    }

    @Test("the held payload never reaches disk")
    func heldPayloadIsMemoryOnly() async throws {
        let suite = "onboarding-auth-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let performer = StubPerformer()
        performer.on("/auth/apple") { _ in (Data(#"{"error":{"code":"internal_error","message":"no"}}"#.utf8), 500) }

        let session = onboardingSession(
            performer,
            drafts: UserDefaultsOnboardingDraftStore(defaults: defaults),
            appleIDs: UserDefaultsAppleUserIDStore(defaults: defaults)
        )
        await session.signIn(with: appleCredential(fullName: "Ada Lovelace"))
        #expect(session.pendingExchange != nil)

        // A lost name is acceptable. A parent's name sitting in UserDefaults is not.
        let written = defaults.dictionaryRepresentation()
        let serialized = written.values.map { String(describing: $0) }.joined()
        #expect(serialized.contains("Ada Lovelace") == false)
    }

    // MARK: The server owns the display name

    /// Apple's `fullName` goes out in the request and is never seen again. Everything the app
    /// renders comes from the `user` object the server answered with.
    @Test("the display name the app holds is the server's, never Apple's")
    func serverUserIsTheSourceOfTruth() async throws {
        let record = InMemoryUserRecordStore()
        let performer = StubPerformer()
        // The server already knows this account by another name — first-write-wins means the
        // name Apple just supplied does *not* replace it, and the client must show the winner.
        performer.on("/auth/apple") { _ in (onboardingSessionJSON(displayName: "Stored Name"), 200) }
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let session = onboardingSession(performer, record: record)
        await session.signIn(with: appleCredential(fullName: "Apple Name"))

        #expect(session.account.user?.displayName == "Stored Name")
        #expect(record.load()?.displayName == "Stored Name")
        #expect(record.load()?.displayName != "Apple Name", "Apple's name is not client-local truth")
    }

    @Test("a null display name from the server stays null rather than falling back to Apple's")
    func nullServerNameIsNotBackfilled() async throws {
        let performer = StubPerformer()
        performer.on("/auth/apple") { _ in (onboardingSessionJSON(displayName: nil), 200) }
        performer.on("/children") { _ in (Data("[]".utf8), 200) }

        let session = onboardingSession(performer)
        await session.signIn(with: appleCredential(fullName: "Apple Name"))

        #expect(session.account.user != nil)
        #expect(session.account.user?.displayName == nil)
    }

    // MARK: Revocation

    @Test("a credential revoked in Settings returns to signedOut without losing anything else")
    func revokedCredentialSignsOutCleanly() async throws {
        let performer = StubPerformer()
        performer.on("/children") { _ in (meChildrenJSON(UUID()), 200) }

        let appleIDs = InMemoryAppleUserIDStore("001.apple.subject")
        let session = onboardingSession(
            performer,
            tokens: TokenPair(accessToken: "a", refreshToken: "r"),
            appleIDs: appleIDs,
            credentials: StubCredentialCheck(.revoked)
        )
        await session.resume()

        #expect(session.state == .signedOut)
        #expect(appleIDs.load() == nil, "the subject goes with the session")
        #expect(await session.account.api.hasSession() == false)
        #expect(performer.count(for: "/children") == 0, "no point asking; we are not signed in")
    }

    @Test("notFound is treated the same as revoked")
    func notFoundSignsOutCleanly() async throws {
        let performer = StubPerformer()
        let session = onboardingSession(
            performer,
            tokens: TokenPair(accessToken: "a", refreshToken: "r"),
            appleIDs: InMemoryAppleUserIDStore("001.apple.subject"),
            credentials: StubCredentialCheck(.notFound)
        )
        await session.resume()
        #expect(session.state == .signedOut)
    }

    /// `getCredentialState` needs the network. Signing someone out of their own archive because
    /// a train went into a tunnel is the worse failure by a distance.
    @Test("an undeterminable credential state keeps the session")
    func unknownCredentialStateKeepsTheSession() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/children") { _ in (meChildrenJSON(child), 200) }

        let session = onboardingSession(
            performer,
            tokens: TokenPair(accessToken: "a", refreshToken: "r"),
            appleIDs: InMemoryAppleUserIDStore("001.apple.subject"),
            credentials: StubCredentialCheck(.unknown)
        )
        await session.resume()

        #expect(session.state.readyChild?.id == child)
    }
}

extension SessionState {
    /// The child behind `.ready`, so a test can assert on identity without matching a whole
    /// decoded row.
    var readyChild: ChildResponse? {
        if case .ready(let child) = self { return child }
        return nil
    }
}

// MARK: - Fixtures

/// Always non-nil where Apple would send one, so a test says which case it is testing.
func appleCredential(fullName: String?, userID: String = "001.apple.subject") -> AppleCredentialInput {
    AppleCredentialInput(
        userID: userID,
        identityToken: "identity-token",
        authorizationCode: "auth-code",
        fullName: fullName
    )
}

/// `SessionResponse` — the same shape `/auth/apple` and `/auth/dev-login` both answer with.
func onboardingSessionJSON(displayName: String?) -> Data {
    Data("""
    {"access_token":"access","refresh_token":"refresh","token_type":"bearer","expires_in":900,
     "user":{"id":"\(UUID().uuidString)","email":"parent@example.com",
             "display_name":\(displayName.map { "\"\($0)\"" } ?? "null"),
             "is_admin":false,"created_at":"2026-08-08T00:00:00Z"}}
    """.utf8)
}

nonisolated final class StubCredentialCheck: AppleCredentialChecking, @unchecked Sendable {
    private let result: AppleCredentialState

    init(_ result: AppleCredentialState) { self.result = result }

    func state(forUserID userID: String) async -> AppleCredentialState { result }
}

// MARK: - Reading what went out

extension StubPerformer {
    func rawBodies(forPathContaining path: String) -> [Data] {
        requests
            .filter { $0.url?.path().contains(path) ?? false }
            .compactMap(\.httpBody)
    }

    func rawBody(forPathContaining path: String) -> Data? {
        rawBodies(forPathContaining: path).last
    }

    func bodies(forPathContaining path: String) -> [[String: Any]] {
        rawBodies(forPathContaining: path).compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }

    func body(forPathContaining path: String) -> [String: Any]? {
        bodies(forPathContaining: path).last
    }

    /// Requests to a path, by HTTP method — `GET /children` and `POST /children` share a path,
    /// and the duplicate-child guard is entirely about telling them apart.
    func count(forPathContaining path: String, method: String) -> Int {
        requests.filter {
            ($0.url?.path().contains(path) ?? false) && $0.httpMethod == method
        }.count
    }
}
