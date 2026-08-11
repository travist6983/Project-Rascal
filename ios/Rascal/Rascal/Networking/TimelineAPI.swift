import Foundation

/// The archive's endpoints — the timeline, one entry, and On This Day.
///
/// Same shape as `RascalAPI.swift`: one place that knows path strings, so a contract change is
/// a single edit rather than a search across views.
extension APIClient {

    /// `GET /v1/entries`. Newest first by `occurred_at`, with media summaries inline — the
    /// list screen must never fan out into a call per entry.
    ///
    /// `cursor` is the opaque `next_cursor` from the previous page and nothing else. It encodes
    /// `(occurred_at, id)`, so paging survives a 2019 photo being added tonight; an offset would
    /// silently skip whatever shifted past the boundary.
    /// `q` switches the same endpoint into full-text search over titles, bodies, captions, and
    /// **the transcripts the phone wrote back** — ordered by relevance, then newest first, and
    /// keyset-paginated on `(rank, occurred_at, id)` instead of `(occurred_at, id)`.
    ///
    /// **A cursor from one mode is not valid in the other**, and the server answers `422` rather
    /// than a quietly wrong page. That is why search keeps its own model and its own cursor
    /// rather than borrowing the timeline's — see `TimelineSearchModel`.
    func entries(
        childId: UUID,
        type: String? = nil,
        tag: String? = nil,
        query: String? = nil,
        before: Date? = nil,
        after: Date? = nil,
        /// `?sealed=` — `true` for only sealed rows, `false` for only unsealed, absent for both.
        /// Sealing is `unlock_at_age`, not an `entry_type`, so it needs its own parameter; the
        /// Sealed chip used to have none and paged the whole archive narrowing locally.
        sealed: Bool? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> EntryPageResponse {
        var items = [URLQueryItem(name: "child_id", value: childId.uuidString.lowercased())]
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        if let type { items.append(URLQueryItem(name: "type", value: type)) }
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        if let tag { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let sealed { items.append(URLQueryItem(name: "sealed", value: sealed ? "true" : "false")) }
        if let before { items.append(URLQueryItem(name: "before", value: ISO8601Formatters.string(from: before))) }
        if let after { items.append(URLQueryItem(name: "after", value: ISO8601Formatters.string(from: after))) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(.get, "v1/entries?\(Self.query(items))")
    }

    /// `GET /v1/entries/{id}` — everything, including transcripts and the originating prompt.
    func entry(id: UUID) async throws -> EntryResponse {
        try await send(.get, "v1/entries/\(id.uuidString.lowercased())")
    }

    /// `PATCH /v1/entries/{id}`.
    ///
    /// The server uses `exclude_unset`, so an absent key means "leave it alone" and an explicit
    /// `null` means "clear it". `EntryChanges` keeps those distinct — encoding a nil optional as
    /// an omitted key would make deleting the text of an entry silently do nothing.
    @discardableResult
    func updateEntry(id: UUID, changes: EntryChanges) async throws -> EntryResponse {
        try await send(.patch, "v1/entries/\(id.uuidString.lowercased())", body: changes)
    }

    /// `DELETE /v1/entries/{id}` — soft delete. The row stays and syncs with `deleted_at` set;
    /// nothing is ever removed from the archive.
    func deleteEntry(id: UUID) async throws {
        _ = try await send(
            .delete, "v1/entries/\(id.uuidString.lowercased())", as: EmptyResponse.self
        )
    }

    /// `GET /v1/children/{id}/moments`. `date` is a calendar day in the child's timezone, and
    /// the server defaults to its own idea of today — which is the right one, because the client
    /// does not get to decide what day it is.
    func moments(childId: UUID, date: String? = nil) async throws -> MomentsResponse {
        let path = "v1/children/\(childId.uuidString.lowercased())/moments"
        guard let date else { return try await send(.get, path) }
        return try await send(.get, "\(path)?\(Self.query([URLQueryItem(name: "date", value: date)]))")
    }

    /// Percent-encoding for a query string. A cursor is base64url and a tag can hold anything a
    /// parent typed, so neither may be pasted into a URL raw.
    static func query(_ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }
}

/// A PATCH body where "not mentioned" and "set to nothing" are different requests.
///
/// `JSONEncoder` drops a nil optional, which collapses the two. Every field here is therefore
/// a `Change`: `.unchanged` writes no key at all, `.set(value)` writes the key — including when
/// the value is null.
/// A tag on the wire, with its provenance.
///
/// `entry_tags.source` is what lets a tag the parent typed be told apart from one the on-device
/// model extracted. The server defaults an unqualified tag to `user`; this client is always
/// explicit, because the only reason it writes tags at all is extraction.
nonisolated struct EntryTagWrite: Encodable, Sendable, Equatable {
    let name: String
    let source: EntryTagSource
}

nonisolated enum EntryTagSource: String, Encodable, Sendable, Equatable {
    case user
    case deviceAI = "device_ai"
}

nonisolated struct EntryChanges: Encodable, Sendable {
    enum Change<Value: Encodable & Sendable>: Sendable {
        case unchanged
        case set(Value)
    }

    var title: Change<String?> = .unchanged
    var body: Change<String?> = .unchanged
    var occurredAt: Change<Date> = .unchanged
    var unlockAtAge: Change<Int?> = .unchanged
    /// Each tag carries who decided it. **A source absent from the payload is left alone**
    /// server-side, so an extraction write carrying only `device_ai` tags cannot touch a tag the
    /// parent typed, and a parent's tag edit cannot eat the model's. See `docs/api-contract.md`.
    var tags: Change<[EntryTagWrite]> = .unchanged

    private enum CodingKeys: String, CodingKey {
        case title, body, occurredAt, unlockAtAge, tags
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if case .set(let value) = title { try container.encode(value, forKey: .title) }
        if case .set(let value) = body { try container.encode(value, forKey: .body) }
        if case .set(let value) = occurredAt { try container.encode(value, forKey: .occurredAt) }
        if case .set(let value) = unlockAtAge { try container.encode(value, forKey: .unlockAtAge) }
        if case .set(let value) = tags { try container.encode(value, forKey: .tags) }
    }
}
