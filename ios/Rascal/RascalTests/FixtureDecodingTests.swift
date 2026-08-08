import Foundation
import Testing

@testable import Rascal

/// Decodes the committed fixtures — real captured responses, not hand-written guesses — and
/// asserts real values. If the server's shape moves, these fail here rather than at runtime on
/// a phone. Re-capture with `make fixtures` from the repo root.
///
/// Fixtures are read from the source tree via `#filePath` rather than copied into the test
/// bundle, so there is exactly one copy and it is the one the API produced.
enum Fixtures {
    static var directory: URL {
        URL(filePath: #filePath)          // …/ios/Rascal/RascalTests/FixtureDecodingTests.swift
            .deletingLastPathComponent()  // …/RascalTests
            .deletingLastPathComponent()  // …/Rascal
            .deletingLastPathComponent()  // …/ios
            .appending(path: "Fixtures")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try APIClient.decoder.decode(type, from: data(name))
    }
}

@Suite("Fixture decoding")
struct FixtureDecodingTests {

    @Test("dev-login decodes into a session with both tokens")
    func devLogin() throws {
        let session = try Fixtures.decode(SessionResponse.self, from: "dev-login.json")

        #expect(session.tokenType == "bearer")
        #expect(session.expiresIn == 900)
        #expect(session.user.email == "dev@rascal.local")
        #expect(session.user.displayName == "Dev Parent")
        // dev-login force-sets this so the fixture account can seed the library.
        #expect(session.user.isAdmin)
        #expect(!session.accessToken.isEmpty)
        // Both halves are present. Dropping the refresh token is the bug that forces a logout.
        #expect(!session.refreshToken.isEmpty)
    }

    @Test("today decodes with all three sections")
    func today() throws {
        let today = try Fixtures.decode(TodayResponse.self, from: "today.json")

        #expect(today.child.name == "Rascal")
        #expect(today.child.ageMonths > 0)
        #expect(!today.today.isEmpty)

        let first = try #require(today.today.first)
        #expect(!first.body.isEmpty)
        #expect(first.status == .pending)
        #expect(first.expiresOn != nil)
    }

    @Test("every slot and kind in the fixture round-trips through the typed accessors")
    func typedAccessors() throws {
        let today = try Fixtures.decode(TodayResponse.self, from: "today.json")

        for item in today.today + today.waiting + today.doneToday {
            // Unknown values must degrade to a neutral card, never crash and never blank.
            #expect(item.slotKind.displayName.isEmpty == false)
            #expect(item.promptKind.badgeText.isEmpty == false)
            #expect(!item.body.isEmpty, "a card with no body would render empty")
        }
    }

    @Test("age_months is read from the server, never computed here")
    func ageIsServerComputed() throws {
        let today = try Fixtures.decode(TodayResponse.self, from: "today.json")
        // The client displays this. Recomputing it from birthdate would drift from the
        // server's answer the moment a timezone or rounding rule differs.
        #expect(today.child.ageMonths == 62)
    }

    @Test("fractional-second timestamps parse")
    func fractionalSeconds() throws {
        let withFraction = try #require(ISO8601Formatters.parse("2026-08-14T18:22:00.481Z"))
        let without = try #require(ISO8601Formatters.parse("2026-08-14T18:22:00Z"))
        // Tolerance, not equality: 0.481 is not representable in binary floating point and
        // the parse lands on 0.4809999465942383. What matters is that the fraction survived.
        #expect(abs(withFraction.timeIntervalSince(without) - 0.481) < 0.001)
    }

    @Test("the error envelope decodes into typed codes")
    func errorEnvelope() throws {
        let json = #"{"error":{"code":"assignment_expired","message":"Too late","field":null}}"#
        let envelope = try APIClient.decoder.decode(APIErrorEnvelope.self, from: Data(json.utf8))
        #expect(envelope.error.code == .assignmentExpired)
        #expect(envelope.error.field == nil)
    }

    @Test("an unrecognised error code degrades instead of throwing")
    func unknownErrorCode() throws {
        let json = #"{"error":{"code":"some_future_code","message":"?","field":null}}"#
        let envelope = try APIClient.decoder.decode(APIErrorEnvelope.self, from: Data(json.utf8))
        #expect(envelope.error.code == .unknown("some_future_code"))
    }
}
