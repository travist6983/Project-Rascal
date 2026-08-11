import Foundation
import Testing

@testable import Rascal

// MARK: - Which APNs host

@Suite("Push environment")
struct PushEnvironmentTests {

    /// **Asserted, not assumed.** Getting this wrong ships a feature that works under Xcode and
    /// delivers nothing to TestFlight, with no error on either side to explain it.
    ///
    /// The assertion is written against the same `#if DEBUG` the property uses, so it holds in
    /// whichever configuration the suite is compiled in rather than passing vacuously in one.
    @Test("sandbox in Debug, production in Release")
    func environmentFollowsBuildConfiguration() {
        #if DEBUG
        #expect(PushEnvironment.current == .sandbox)
        #else
        #expect(PushEnvironment.current == .production)
        #endif
    }

    @Test("Both cases encode as the strings the server accepts")
    func wireValues() throws {
        #expect(PushEnvironment.sandbox.rawValue == "sandbox")
        #expect(PushEnvironment.production.rawValue == "production")
        // The server's `PushEnvironment` literal has exactly these two members, so a third case
        // added here without a server change would be silently rejected.
        #expect(PushEnvironment.allCases.count == 2)
    }
}

// MARK: - Where a tap lands

@Suite("Notification payload routing")
struct NotificationPayloadTests {

    /// The exact shape `PushMessage.payload()` builds, top-level `assignment_id` and all.
    private func payload(assignmentId: String?) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Today's mission", "body": "Ask him what made him laugh."],
                    "sound": "default"]
        ]
        if let assignmentId { userInfo["assignment_id"] = assignmentId }
        return userInfo
    }

    @Test("A valid assignment id routes to that assignment")
    func validIdRoutesToAssignment() {
        let id = UUID()
        let link = NotificationPayload.link(from: payload(assignmentId: id.uuidString))
        #expect(link == .assignment(id))
    }

    @Test("A lowercase id parses — the server sends them lowercased")
    func lowercaseIdParses() {
        let id = UUID()
        let link = NotificationPayload.link(from: payload(assignmentId: id.uuidString.lowercased()))
        #expect(link == .assignment(id))
    }

    @Test("An unparseable id lands on Today, never on a broken composer")
    func unknownIdLandsOnToday() {
        #expect(NotificationPayload.link(from: payload(assignmentId: "not-a-uuid")) == .today)
    }

    @Test("A payload with no assignment lands on Today")
    func missingIdLandsOnToday() {
        #expect(NotificationPayload.link(from: payload(assignmentId: nil)) == .today)
    }

    @Test("An empty payload lands on Today")
    func emptyPayloadLandsOnToday() {
        #expect(NotificationPayload.link(from: [:]) == .today)
    }

    /// A *stale* id — one that parses but names an assignment this device does not hold — is
    /// turned away one layer down, by the widget's resolver. This asserts the notification path
    /// reaches that same resolver rather than a second copy of the rule.
    @MainActor
    @Test("A stale assignment id resolves to Today through the widget's own router")
    func staleIdResolvesToTodayThroughSharedRouter() {
        let board = TodayBoard(
            date: "2026-08-10",
            child: ChildSummary(id: UUID(), name: "Kid", ageMonths: 48),
            today: [],
            waiting: [],
            doneToday: []
        )
        let link = NotificationPayload.link(from: payload(assignmentId: UUID().uuidString))
        guard case .assignment(let id) = link else {
            Issue.record("expected an assignment link")
            return
        }
        #expect(board.route(forAssignment: id) == .today)
    }
}

// MARK: - The wall-clock time

@Suite("NotifyTime")
struct NotifyTimeTests {

    @Test("Parses both the two-part and three-part wire forms")
    func parsesWireForms() {
        #expect(NotifyTime(wire: "19:00") == NotifyTime(hour: 19, minute: 0))
        #expect(NotifyTime(wire: "19:00:00") == NotifyTime(hour: 19, minute: 0))
        #expect(NotifyTime(wire: "07:05:30") == NotifyTime(hour: 7, minute: 5))
    }

    @Test("Refuses nonsense rather than clamping it into a plausible time")
    func refusesNonsense() {
        #expect(NotifyTime(wire: "") == nil)
        #expect(NotifyTime(wire: "25:00") == nil)
        #expect(NotifyTime(wire: "19:60") == nil)
        #expect(NotifyTime(wire: "evening") == nil)
        #expect(NotifyTime(wire: "19") == nil)
    }

    @Test("Round-trips through JSON as the single string the server sends")
    func codableRoundTrip() throws {
        let time = NotifyTime(hour: 7, minute: 15)
        let data = try JSONEncoder().encode(time)
        #expect(String(data: data, encoding: .utf8) == "\"07:15:00\"")
        #expect(try JSONDecoder().decode(NotifyTime.self, from: data) == time)
    }

    @Test("The default matches the server's DEFAULT_NOTIFY_LOCAL_TIME")
    func defaultMatchesServer() {
        #expect(NotifyTime.default == NotifyTime(hour: 19, minute: 0))
        #expect(NotifyTime.default.wire == "19:00:00")
    }
}

// MARK: - The request body

@Suite("PATCH /v1/me request encoding")
struct MeUpdateEncodingTests {

    /// **An absent key means "no opinion"; an explicit `null` is a rejection.** The server reads
    /// `model_fields_set`, so this distinction decides whether a parent changing the notification
    /// time also blanks their display name.
    @Test("Unset fields are omitted, not sent as null")
    func unsetFieldsAreOmitted() throws {
        struct Body: Encodable {
            let displayName: String?
            let notifyEnabled: Bool?
            let notifyLocalTime: NotifyTime?
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let onlyTime = Body(displayName: nil, notifyEnabled: nil, notifyLocalTime: NotifyTime(hour: 7, minute: 0))
        let json = String(data: try encoder.encode(onlyTime), encoding: .utf8) ?? ""

        #expect(json.contains("notify_local_time"))
        #expect(json.contains("display_name") == false)
        #expect(json.contains("notify_enabled") == false)
        #expect(json.contains("null") == false)
    }
}

// MARK: - The user record

@Suite("UserResponse decoding")
struct UserResponseDecodingTests {

    @Test("Decodes the notification preference the server sends")
    func decodesPreference() throws {
        let json = """
        {"id":"\(UUID().uuidString)","email":"a@b.c","display_name":"Parent","is_admin":false,
         "notify_enabled":true,"notify_local_time":"07:30:00","created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let user = try APIClient.decoder.decode(UserResponse.self, from: json)
        #expect(user.notifyEnabled)
        #expect(user.notifyLocalTime == NotifyTime(hour: 7, minute: 30))
    }

    /// **The upgrade case.** A record persisted by the previous build has no `notify_*` keys.
    /// Throwing here would make `UserRecordStore` read the account as absent, and Settings would
    /// show a nameless parent on the first cold start after the update.
    @Test("A record written by the previous build still decodes")
    func decodesLegacyRecord() throws {
        let json = """
        {"id":"\(UUID().uuidString)","email":"a@b.c","display_name":"Parent","is_admin":false,
         "created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let user = try APIClient.decoder.decode(UserResponse.self, from: json)
        #expect(user.displayName == "Parent")
        #expect(user.notifyEnabled == false)
        #expect(user.notifyLocalTime == .default)
    }
}
