import Foundation

/// `GET /v1/sync` — everything about one child that changed since a cursor.
///
/// Same shape as `RascalAPI.swift` and `TimelineAPI.swift`: one place that knows path strings, so
/// a contract change is a single edit rather than a search across the data layer.
extension APIClient {

    /// Everything whose `updated_at` is strictly after `since`, **including soft-deleted rows**.
    ///
    /// `since` is the cursor from the previous call and nothing else. Omitting it asks for a full
    /// snapshot, which is both the cold-start path and the recovery path when a stored cursor
    /// cannot be read.
    ///
    /// **The response is a page.** `limit` caps each of the four collections independently —
    /// the server's default is 500 and its maximum 2000 — and `has_more` is true while any of
    /// them was cut. The engine loops for two reasons: the cursor comes back lagged, so a second
    /// call closes the gap between the lagged position and the present, and a cursor that stops
    /// advancing while `has_more` is still true is the server's documented stuck state, whose
    /// remedy is a larger page. (This comment said *"this endpoint does not page"* from Aug 9 to
    /// Sep 3, 2026; it was true for four days.)
    ///
    /// `limit` is nil for the server's default, and only the engine's escalation sets it.
    func syncPull(childId: UUID, since: Date?, limit: Int? = nil) async throws -> SyncPullResponse {
        var items = [URLQueryItem(name: "child_id", value: childId.uuidString.lowercased())]
        if let since {
            items.append(URLQueryItem(name: "since", value: ISO8601Formatters.string(from: since)))
        }
        if let limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return try await send(.get, "v1/sync?\(Self.query(items))")
    }
}
