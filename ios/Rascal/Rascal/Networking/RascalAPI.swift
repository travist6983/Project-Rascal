import Foundation

/// The endpoints this phase uses. One place that knows path strings, so a contract change is
/// a single edit rather than a search across views.
extension APIClient {

    func today(childId: UUID, date: String? = nil) async throws -> TodayResponse {
        let path = date.map { "v1/children/\(childId.uuidString.lowercased())/today?date=\($0)" }
            ?? "v1/children/\(childId.uuidString.lowercased())/today"
        return try await send(.get, path)
    }

    func children() async throws -> [ChildResponse] {
        try await send(.get, "v1/children")
    }

    /// The assignment flips to `done` in the same transaction that creates the entry, so this
    /// is the only call a completion needs.
    ///
    /// `Idempotency-Key` makes a retry safe: a replay returns the original 201 body
    /// byte-for-byte, never a second row and never a 409. That is what lets a failed save sit
    /// in SwiftData and retry on next foreground without risking a duplicate.
    func createEntry(_ entry: Entry, tags: [String] = []) async throws -> EntryResponse {
        try await send(
            .post, "v1/entries",
            body: EntryCreateRequest(
                id: entry.id,
                childId: entry.childId,
                assignmentId: entry.assignmentId,
                occurredAt: entry.occurredAt,
                title: entry.title,
                body: entry.body,
                unlockAtAge: entry.unlockAtAge,
                tags: tags
            ),
            headers: ["Idempotency-Key": entry.idempotencyKey.uuidString]
        )
    }

    func dismissAssignment(_ id: UUID) async throws {
        _ = try await send(.post, "v1/assignments/\(id.uuidString.lowercased())/dismiss", as: EmptyResponse.self)
    }
}

struct ChildResponse: Decodable, Identifiable {
    let id: UUID
    let name: String
    let birthdate: String
    let familyTimezone: String
    let ageMonths: Int
    let role: String
}
