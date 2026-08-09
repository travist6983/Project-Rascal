import Foundation
import Testing

@testable import Rascal

/// `GET /me`, and the record it keeps.
///
/// The defect this closes: the user record arrived exactly once, with the sign-in response, so
/// after a force quit the app had a valid session and no idea whose it was. Settings could not
/// show the account's own name.
@MainActor
@Suite("Account record")
struct MeTests {

    private func session(
        _ performer: StubPerformer,
        record: UserRecordStoring = InMemoryUserRecordStore(),
        tokens: TokenPair? = TokenPair(accessToken: "a", refreshToken: "r")
    ) -> AppSession {
        let store = InMemoryTokenStore(tokens)
        return AppSession(
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: store
            ),
            tokens: store,
            record: record
        )
    }

    @Test("a warm start re-reads the account instead of shrugging")
    func warmStartRefreshesTheUser() async throws {
        let performer = StubPerformer()
        let child = UUID()
        performer.on("/children") { _ in (meChildrenJSON(child), 200) }
        performer.on("/me") { _ in (meUserJSON(name: "Travis"), 200) }

        let session = session(performer)
        await session.start()

        #expect(session.phase == .signedIn(childId: child))
        #expect(session.user?.displayName == "Travis")
        #expect(performer.count(for: "/me") == 1)
    }

    @Test("the record survives a relaunch, so the name is there before any request goes out")
    func recordIsPersistedAcrossLaunches() async throws {
        let record = InMemoryUserRecordStore()
        let performer = StubPerformer()
        let child = UUID()
        performer.on("/children") { _ in (meChildrenJSON(child), 200) }
        performer.on("/me") { _ in (meUserJSON(name: "Travis"), 200) }

        await session(performer, record: record).start()

        // A second launch, before anything has been fetched.
        let relaunched = session(StubPerformer(), record: record)
        #expect(relaunched.user?.displayName == "Travis")
    }

    @Test("offline, the stored record stands rather than being cleared")
    func offlineKeepsTheStoredRecord() async throws {
        let record = InMemoryUserRecordStore()
        let child = UUID()
        let warm = StubPerformer()
        warm.on("/children") { _ in (meChildrenJSON(child), 200) }
        warm.on("/me") { _ in (meUserJSON(name: "Travis"), 200) }
        await session(warm, record: record).start()

        // Relaunch with the server unreachable.
        let cold = StubPerformer()
        cold.on("/children") { _ in (meChildrenJSON(child), 200) }
        cold.on("/me") { _ in (Data("{}".utf8), 500) }
        let session = session(cold, record: record)
        await session.start()

        #expect(session.user?.displayName == "Travis", "a failed refresh is not a reason to forget")
        #expect(session.phase == .signedIn(childId: child), "and it must not fail the launch")
    }

    @Test("a rename on another device lands on the next launch")
    func refreshPicksUpARemoteRename() async throws {
        let record = InMemoryUserRecordStore()
        let child = UUID()
        let first = StubPerformer()
        first.on("/children") { _ in (meChildrenJSON(child), 200) }
        first.on("/me") { _ in (meUserJSON(name: "Travsi"), 200) }
        await session(first, record: record).start()

        let second = StubPerformer()
        second.on("/children") { _ in (meChildrenJSON(child), 200) }
        second.on("/me") { _ in (meUserJSON(name: "Travis"), 200) }
        let session = session(second, record: record)
        await session.start()

        #expect(session.user?.displayName == "Travis")
        #expect(record.load()?.displayName == "Travis", "and the stored copy is corrected too")
    }

    @Test("a nil display name round-trips as nil rather than as words")
    func nilNameRoundTrips() async throws {
        let record = InMemoryUserRecordStore()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/children") { _ in (meChildrenJSON(child), 200) }
        performer.on("/me") { _ in (meUserJSON(name: nil, email: nil), 200) }

        let session = session(performer, record: record)
        await session.start()

        // Apple's relay addresses are unreliable and both columns are nullable because of it.
        // "Not set" is Settings' word for this, and it must be Settings' word rather than a
        // string that got baked in somewhere down here.
        #expect(session.user != nil)
        #expect(session.user?.displayName == nil)
        #expect(session.user?.email == nil)
        #expect(record.load()?.displayName == nil)
    }

    @Test("signing out forgets the record along with the token")
    func signOutClearsTheRecord() async throws {
        let record = InMemoryUserRecordStore()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/children") { _ in (meChildrenJSON(child), 200) }
        performer.on("/me") { _ in (meUserJSON(name: "Travis"), 200) }
        performer.on("/logout") { _ in (Data("{}".utf8), 200) }

        let session = session(performer, record: record)
        await session.start()
        #expect(record.load() != nil)

        await session.signOut()

        #expect(session.user == nil)
        #expect(record.load() == nil, "leaving a name behind is not what signed out means")
        #expect(session.phase == .signedOut)
    }

    @Test("a record that cannot be decoded is treated as absent")
    func corruptRecordIsIgnored() throws {
        let suite = "me-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not a user".utf8), forKey: "session.user")
        let store = UserDefaultsUserRecordStore(defaults: defaults)

        // One request corrects it. A half-written record honoured would put a stale name on the
        // account screen with no way for anyone to work out why.
        #expect(store.load() == nil)
    }

    @Test("the stored record round-trips through the real store")
    func recordRoundTripsThroughUserDefaults() throws {
        let suite = "me-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsUserRecordStore(defaults: defaults)
        let decoded = try APIClient.decoder.decode(UserResponse.self, from: meUserJSON(name: "Travis"))
        store.save(decoded)

        let loaded = try #require(store.load())
        #expect(loaded == decoded, "including created_at, which is a date on both sides of this")

        store.clear()
        #expect(store.load() == nil)
    }
}

/// One `UserOut`, mirroring `api/src/rascal/schemas/common.py`.
///
/// A free function rather than a method on the suite, for the reason `TimelineFixtures` gives:
/// the stub performer's closures are `@Sendable` and cannot reach a main-actor-isolated helper.
func meUserJSON(name: String?, email: String? = "travis@example.com") -> Data {
    Data("""
    {"id":"\(UUID().uuidString)","email":\(email.map { "\"\($0)\"" } ?? "null"),
     "display_name":\(name.map { "\"\($0)\"" } ?? "null"),
     "is_admin":false,"created_at":"2026-08-08T00:00:00Z"}
    """.utf8)
}

func meChildrenJSON(_ id: UUID) -> Data {
    Data("""
    [{"id":"\(id.uuidString)","name":"Rascal","birthdate":"2021-06-01",
      "family_timezone":"America/Detroit","age_months":62,"role":"parent"}]
    """.utf8)
}
