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
    /// **This endpoint does not page.** There is no `limit` and no `cursor` parameter on it —
    /// verified against `api/src/rascal/routers/sync.py`, which declares exactly one query
    /// parameter besides `child_id`. One call returns the whole delta. The engine still loops,
    /// for a different reason: the cursor comes back lagged, so a second call is what closes the
    /// gap between the lagged position and the present.
    func syncPull(childId: UUID, since: Date?) async throws -> SyncPullResponse {
        var items = [URLQueryItem(name: "child_id", value: childId.uuidString.lowercased())]
        if let since {
            items.append(URLQueryItem(name: "since", value: ISO8601Formatters.string(from: since)))
        }
        return try await send(.get, "v1/sync?\(Self.query(items))")
    }
}
