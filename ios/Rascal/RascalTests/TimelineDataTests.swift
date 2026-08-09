import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The layer under the timeline: the wire shapes, the cache reconcile, and the rules about
/// which side wins when the two disagree.

// MARK: - Decoding

@Suite("Timeline wire shapes")
struct TimelineWireTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: Data) throws -> T {
        try APIClient.decoder.decode(type, from: json)
    }

    @Test("a page decodes with its media summaries inline and its cursor")
    func decodesPage() throws {
        let photo = UUID()
        let page = try decode(
            EntryPageResponse.self,
            pageJSON(
                [entryJSON(
                    id: UUID(), childId: UUID(), occurredAt: Date(), type: "photo",
                    tags: ["swimming"], media: [mediaJSON(id: photo)]
                )],
                cursor: "eyJvIjoi"
            )
        )

        #expect(page.nextCursor == "eyJvIjoi")
        let entry = try #require(page.entries.first)
        // The whole point of inlining: the list renders without a call per entry.
        #expect(entry.media.count == 1)
        #expect(entry.media.first?.id == photo)
        #expect(entry.mediaCount == 1)
        #expect(entry.tags.map(\.name) == ["swimming"])
        #expect(entry.prompt == nil, "a list row carries no prompt")
    }

    @Test("the last page has no cursor")
    func lastPageHasNoCursor() throws {
        let page = try decode(EntryPageResponse.self, pageJSON([], cursor: nil))
        #expect(page.entries.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("an entry with no tags or media key still decodes")
    func decodesLeniently() throws {
        // A card with no chips is a card. A card that fails to decode is a hole in the archive.
        let json = Data("""
        {"id":"\(UUID().uuidString)","child_id":"\(UUID().uuidString)","assignment_id":null,
         "occurred_at":"2026-08-08T10:00:00.000Z","created_at":"2026-08-08T10:00:00.000Z",
         "updated_at":"2026-08-08T10:00:00.000Z","deleted_at":null,"title":null,"body":"x",
         "entry_type":"text","child_age_months":62,"unlock_at_age":null}
        """.utf8)
        let entry = try decode(EntryResponse.self, json)
        #expect(entry.tags.isEmpty)
        #expect(entry.media.isEmpty)
        #expect(entry.mediaCount == 0)
    }

    @Test("detail carries the originating prompt and a transcript")
    func decodesDetail() throws {
        let entry = try decode(
            EntryResponse.self,
            Data(entryJSON(
                id: UUID(), childId: UUID(), occurredAt: Date(), type: "audio",
                media: [mediaJSON(kind: "audio", duration: 34, transcript: "we went to the pond")],
                prompt: "Record him telling you a story"
            ).utf8)
        )
        #expect(entry.prompt?.body == "Record him telling you a story")
        #expect(entry.media.first?.transcript == "we went to the pond")
        #expect(entry.media.first?.durationSeconds == 34)
    }

    @Test("moments decodes both the grouped answer and the warm redirect")
    func decodesMoments() throws {
        let grouped = try decode(MomentsResponse.self, Data("""
        {"date":"2026-08-08","fallback":null,
         "groups":[{"years_ago":2,"entries":[\(entryJSON(id: UUID(), childId: UUID(), occurredAt: Date()))]}],
         "entries":[]}
        """.utf8))
        #expect(grouped.isFallback == false)
        #expect(grouped.groups.first?.yearsAgo == 2)
        #expect(grouped.groups.first?.title == "2 years ago")
        #expect(grouped.allEntries.count == 1)

        let random = try decode(MomentsResponse.self, Data("""
        {"date":"2026-08-08","fallback":"random","groups":[],
         "entries":[\(entryJSON(id: UUID(), childId: UUID(), occurredAt: Date()))]}
        """.utf8))
        #expect(random.isFallback)
        #expect(random.allEntries.count == 1)
    }

    @Test("a PATCH omits what did not change and sends null for what was cleared")
    func patchDistinguishesUnsetFromNull() throws {
        // The server uses exclude_unset. Encoding a nil optional as an absent key would make
        // "the parent deleted the text" indistinguishable from "the parent didn't touch it",
        // and the old words would stay in the archive.
        let changes = EntryChanges(body: .set(nil), occurredAt: .set(Date(timeIntervalSince1970: 0)))
        let json = try #require(String(data: try APIClient.encoder.encode(changes), encoding: .utf8))

        #expect(json.contains("\"body\":null"))
        #expect(json.contains("occurred_at"))
        #expect(!json.contains("title"), "an unchanged field sends no key at all")
        #expect(!json.contains("tags"))
    }
}

// MARK: - Filtering

@Suite("Timeline filters")
struct TimelineFilterTests {

    @Test("every filter maps to the entry_type the server derives")
    func mapsToServerTypes() {
        #expect(TimelineFilter.all.queryValue == nil)
        #expect(TimelineFilter.photo.queryValue == "photo")
        #expect(TimelineFilter.video.queryValue == "video")
        #expect(TimelineFilter.audio.queryValue == "audio")
        #expect(TimelineFilter.text.queryValue == "text")
        #expect(TimelineFilter.didIt.queryValue == "did_it")
    }

    @Test("the offline filter agrees with the query it would have sent")
    func offlineMatchesOnline() {
        // The same decision, made twice: once as a query parameter, once against a cached row.
        // They must not drift, or a filter would show one archive with signal and another
        // without.
        for filter in TimelineFilter.allCases {
            for type in ["photo", "video", "audio", "text", "did_it"] {
                let online = filter.queryValue == nil || filter.queryValue == type
                #expect(filter.matches(entryType: type) == online, "\(filter) vs \(type)")
            }
        }
    }

    @Test("an entry the server has not typed yet matches only All")
    func untypedMatchesOnlyAll() {
        // Guessing a type on device would be the client deciding something the server owns,
        // and it would be wrong exactly when media is still uploading.
        #expect(TimelineFilter.all.matches(entryType: nil))
        #expect(!TimelineFilter.photo.matches(entryType: nil))
        #expect(!TimelineFilter.didIt.matches(entryType: nil))
    }
}

// MARK: - The cache

@MainActor
@Suite("Entry cache reconcile")
struct EntryCacheTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func response(
        id: UUID,
        childId: UUID = UUID(),
        occurredAt: Date = Date(),
        type: String = "text",
        body: String? = "from the server",
        tags: [String] = [],
        media: [String] = []
    ) throws -> EntryResponse {
        try APIClient.decoder.decode(
            EntryResponse.self,
            from: Data(entryJSON(
                id: id, childId: childId, occurredAt: occurredAt,
                type: type, body: body, tags: tags, media: media
            ).utf8)
        )
    }

    @Test("a server entry becomes one local row")
    func createsRow() throws {
        let context = try makeContext()
        let id = UUID()
        EntryCache.upsert([try response(id: id, tags: ["bedtime"])], into: context)

        let rows = try context.fetch(FetchDescriptor<Entry>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rows.first?.tagNames == ["bedtime"])
        #expect(rows.first?.sync == .synced)
        #expect(rows.first?.existsOnServer == true)
    }

    @Test("an entry written here and fetched back is the same row, never two")
    func reusesClientIdentity() throws {
        // The whole reason entry ids are client-generated. A composer-created row and the row
        // the server hands back are one thing.
        let context = try makeContext()
        let local = Entry(childId: UUID(), occurredAt: Date(), body: "written on the phone")
        local.sync = .synced
        local.existsOnServer = true
        context.insert(local)
        try context.save()

        EntryCache.upsert([try response(id: local.id, body: "written on the phone")], into: context)

        #expect(try context.fetch(FetchDescriptor<Entry>()).count == 1)
    }

    @Test("a local edit the server has not seen is not overwritten")
    func localPendingWins() throws {
        let context = try makeContext()
        let local = Entry(childId: UUID(), occurredAt: Date(), body: "edited on a train")
        local.existsOnServer = true
        local.sync = .pending
        context.insert(local)
        try context.save()

        EntryCache.upsert([try response(id: local.id, body: "the older server copy")], into: context)

        #expect(local.body == "edited on a train")
        #expect(local.sync == .pending, "the sweep still owes this one")
    }

    @Test("a synced row takes the server's title, body, and date")
    func serverWinsOnceSynced() throws {
        let context = try makeContext()
        let backdated = Date(timeIntervalSince1970: 1_500_000_000)
        let local = Entry(childId: UUID(), occurredAt: Date(), body: "stale")
        local.sync = .synced
        local.existsOnServer = true
        context.insert(local)
        try context.save()

        EntryCache.upsert(
            [try response(id: local.id, occurredAt: backdated, body: "edited on the other phone")],
            into: context
        )

        #expect(local.body == "edited on the other phone")
        #expect(abs(local.occurredAt.timeIntervalSince(backdated)) < 1)
    }

    @Test("complete media is cached and incomplete media is not")
    func cachesOnlyCompleteMedia() throws {
        // A row still uploading from another device has no bytes this phone can reach, and
        // creating it here would enrol it in the upload sweep against a file that was never
        // on this device.
        let context = try makeContext()
        let done = UUID()
        let pending = UUID()
        EntryCache.upsert(
            [try response(
                id: UUID(), type: "photo",
                media: [mediaJSON(id: done), mediaJSON(id: pending, status: "pending")]
            )],
            into: context
        )

        let rows = try context.fetch(FetchDescriptor<Media>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == done)
        #expect(rows.first?.state == .complete)
    }

    @Test("a reconcile never drags an upload in flight back to staged")
    func doesNotRewindAnUpload() throws {
        let context = try makeContext()
        let entryId = UUID()
        let media = Media(entryId: entryId, kind: "photo", contentType: "image/jpeg", byteCount: 900)
        media.state = .uploading
        context.insert(media)
        try context.save()

        EntryCache.upsertMedia(
            [try APIClient.decoder.decode(
                MediaSummaryResponse.self,
                from: Data(mediaJSON(id: media.id, status: "pending").utf8)
            )],
            entryId: entryId,
            into: context
        )

        #expect(media.state == .uploading)
    }

    @Test("deleting marks the entry and its media, and removes neither")
    func softDeleteKeepsRows() throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "wrong photo")
        entry.existsOnServer = true
        entry.sync = .synced
        context.insert(entry)
        let media = Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 10)
        context.insert(media)
        try context.save()

        EntryCache.markDeleted(entry, in: context)

        #expect(entry.deletedAt != nil)
        #expect(entry.deletionPending, "the server has not been told yet")
        #expect(media.deletedAt != nil, "a media row left alive keeps rendering the photo")
        // Deletions sync as rows with deleted_at set, never as absences.
        #expect(try context.fetch(FetchDescriptor<Entry>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Media>()).count == 1)
    }

    @Test("a deleted entry is not resurrected by a later reconcile")
    func deletedStaysDeleted() throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "gone")
        entry.existsOnServer = true
        entry.sync = .synced
        context.insert(entry)
        try context.save()
        EntryCache.markDeleted(entry, in: context)

        // The server has not processed the delete yet, so it still lists the entry.
        EntryCache.upsert([try response(id: entry.id, body: "gone")], into: context)

        #expect(entry.deletedAt != nil, "a pending deletion outranks a stale list response")
        #expect(entry.deletionPending)
    }
}

// MARK: - The calls

@MainActor
@Suite("Archive endpoints")
struct ArchiveAPITests {

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("the timeline call carries the child, the filter, and the cursor")
    func buildsTheQuery() async throws {
        let performer = StubPerformer()
        let page = pageJSON([], cursor: nil)
        performer.on("/entries") { _ in (page, 200) }

        let child = UUID()
        _ = try await client(performer).entries(
            childId: child, type: "photo", limit: 50, cursor: "abc=="
        )

        let query = try #require(performer.requests.last?.url?.query)
        #expect(query.contains("child_id=\(child.uuidString.lowercased())"))
        #expect(query.contains("type=photo"))
        #expect(query.contains("limit=50"))
        // Base64url is percent-encoded, not pasted in raw.
        #expect(query.contains("cursor=abc%3D%3D"))
    }

    @Test("a delete is a DELETE, and 204 is success")
    func deletesSoftly() async throws {
        let performer = StubPerformer()
        performer.on("/entries/") { _ in (Data(), 204) }

        try await client(performer).deleteEntry(id: UUID())

        #expect(performer.requests.last?.httpMethod == "DELETE")
    }

    @Test("a deletion made offline is retried on the next sweep")
    func sweepPushesPendingDeletion() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "removed on a train")
        entry.existsOnServer = true
        entry.sync = .synced
        context.insert(entry)
        try context.save()
        EntryCache.markDeleted(entry, in: context)

        let performer = StubPerformer()
        performer.on("/entries/") { _ in (Data(), 204) }

        let sync = EntrySync(api: client(performer), context: context)
        #expect(sync.unsyncedCount() == 1, "an unpushed deletion is outstanding work")

        await sync.sweep()

        #expect(entry.deletionPending == false)
        #expect(performer.requests.contains { $0.httpMethod == "DELETE" })
        #expect(sync.unsyncedCount() == 0)
    }

    @Test("deleting an entry the server never had touches no network")
    func neverSyncedDeletionIsLocalOnly() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "written and binned offline")
        context.insert(entry)
        try context.save()
        EntryCache.markDeleted(entry, in: context)

        let performer = StubPerformer()
        await EntrySync(api: client(performer), context: context).sweep()

        #expect(entry.deletionPending == false)
        #expect(!performer.requests.contains { $0.httpMethod == "DELETE" })
    }

    @Test("a deletion already gone server-side settles rather than retrying forever")
    func notFoundSettlesTheDeletion() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "deleted on the other phone")
        entry.existsOnServer = true
        entry.sync = .synced
        context.insert(entry)
        try context.save()
        EntryCache.markDeleted(entry, in: context)

        let performer = StubPerformer()
        let missing = Data(#"{"error":{"code":"not_found","message":"Entry not found","field":null}}"#.utf8)
        performer.on("/entries/") { _ in (missing, 404) }

        await EntrySync(api: client(performer), context: context).sweep()

        #expect(entry.deletionPending == false, "gone is the outcome that was asked for")
    }

    @Test("a deletion that cannot reach the server stays queued")
    func failedDeletionStaysQueued() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "offline")
        entry.existsOnServer = true
        entry.sync = .synced
        context.insert(entry)
        try context.save()
        EntryCache.markDeleted(entry, in: context)

        let performer = StubPerformer()
        let boom = Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8)
        performer.on("/entries/") { _ in (boom, 500) }

        await EntrySync(api: client(performer), context: context).sweep()

        #expect(entry.deletionPending, "still owed, and the parent still sees it gone")
        #expect(entry.deletedAt != nil)
    }
}
