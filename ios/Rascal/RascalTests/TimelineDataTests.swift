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

    @Test("a list row carries prompt_body even though it carries no prompt object")
    func decodesPromptBodyOnAListRow() throws {
        // The regression this exists for: `EntryOut.prompt_body` shipped, PR #48 deleted the
        // client's assignment-lookup fallback on the strength of it, and nothing decoded the
        // field for the next day. The server sent the sentence and the client dropped it.
        let entry = try decode(
            EntryResponse.self,
            Data(entryJSON(
                id: UUID(), childId: UUID(), occurredAt: Date(), type: "photo",
                promptBody: "Take a picture of what he built"
            ).utf8)
        )
        #expect(entry.prompt == nil, "a list row still carries no prompt object")
        #expect(entry.promptBody == "Take a picture of what he built")
    }

    @Test("a freeform entry decodes with no prompt body rather than failing")
    func decodesFreeformWithNoPromptBody() throws {
        let entry = try decode(
            EntryResponse.self,
            Data(entryJSON(id: UUID(), childId: UUID(), occurredAt: Date()).utf8)
        )
        #expect(entry.promptBody == nil)
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
        #expect(TimelineFilter.all.serverType == nil)
        #expect(TimelineFilter.photo.serverType == "photo")
        #expect(TimelineFilter.video.serverType == "video")
        #expect(TimelineFilter.audio.serverType == "audio")
        #expect(TimelineFilter.text.serverType == "text")
        #expect(TimelineFilter.didIt.serverType == "did_it")
    }

    @Test("the offline filter agrees with the query it would have sent")
    func offlineMatchesOnline() {
        // The same decision, made twice: once as a query parameter, once against a cached row.
        // They must not drift, or a filter would show one archive with signal and another
        // without.
        //
        // Sealed is excluded because there is no query to agree with — see `sealedIsNotAType`.
        for filter in TimelineFilter.allCases where filter.serverSealed == nil {
            for type in ["photo", "video", "audio", "text", "did_it"] {
                let online = filter.serverType == nil || filter.serverType == type
                #expect(filter.matches(entryType: type) == online, "\(filter) vs \(type)")
            }
        }
    }

    @Test("sealed is unlock_at_age, not an entry type, and it says so")
    func sealedIsNotAType() {
        // Two different nils. `all` sends no `type` because it wants everything; `sealed` sends
        // none because sealing is not a type — it goes as `?sealed=true` instead. Collapsing
        // them would make the sealed filter silently show the whole archive, which is the thing
        // this asserts against. Was `isClientSideOnly` until the server grew the parameter.
        #expect(TimelineFilter.sealed.serverType == nil)
        #expect(TimelineFilter.sealed.serverSealed == true)
        #expect(TimelineFilter.all.serverSealed == nil, "All must not narrow to unsealed")
        #expect(TimelineFilter.allCases.filter { $0.serverSealed != nil } == [.sealed])

        // A letter is sealed whatever the server derived its type to be.
        #expect(TimelineFilter.sealed.matches(entryType: "text", unlockAtAge: 18))
        #expect(TimelineFilter.sealed.matches(entryType: "photo", unlockAtAge: 21))
        #expect(!TimelineFilter.sealed.matches(entryType: "text", unlockAtAge: nil))
        // And unsealed filters do not care that it is sealed.
        #expect(TimelineFilter.text.matches(entryType: "text", unlockAtAge: 18))
        #expect(TimelineFilter.all.matches(entryType: "text", unlockAtAge: 18))
    }

    @Test("a sealed letter written on this phone matches before the server has typed it")
    func sealedMatchesUntypedRow() {
        // `unlock_at_age` is the parent's, set at write time — unlike `entry_type`, which the
        // server derives. So this is the one filter that is trustworthy on a row that has never
        // been pushed, and a letter written offline belongs in the sealed list immediately.
        #expect(TimelineFilter.sealed.matches(entryType: nil, unlockAtAge: 18))
        #expect(!TimelineFilter.sealed.matches(entryType: nil, unlockAtAge: nil))
    }

    @Test("the empty-state sentence reads like a sentence for every filter")
    func emptyCopyReadsWell() {
        // Reusing the chip label produced "No photos entries so far", which a device screenshot
        // caught and no assertion would have. These are the finished sentences.
        #expect("No \(TimelineFilter.photo.emptyNoun) so far." == "No photos so far.")
        #expect("No \(TimelineFilter.video.emptyNoun) so far." == "No video so far.")
        #expect("No \(TimelineFilter.audio.emptyNoun) so far." == "No voice notes so far.")
        #expect("No \(TimelineFilter.text.emptyNoun) so far." == "No written entries so far.")
        #expect("No \(TimelineFilter.didIt.emptyNoun) so far." == "No did-it entries so far.")
        #expect("No \(TimelineFilter.sealed.emptyNoun) so far." == "No sealed letters so far.")
        // Nothing anywhere implies a day was missed.
        for filter in TimelineFilter.allCases {
            #expect(!filter.emptyNoun.contains("entries entries"))
            #expect(filter.emptyNoun == filter.emptyNoun.lowercased())
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
        media: [String] = [],
        prompt: String? = nil,
        promptBody: String? = nil
    ) throws -> EntryResponse {
        try APIClient.decoder.decode(
            EntryResponse.self,
            from: Data(entryJSON(
                id: id, childId: childId, occurredAt: occurredAt,
                type: type, body: body, tags: tags, media: media,
                prompt: prompt, promptBody: promptBody
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

    @Test("a list row's prompt_body reaches the cached entry, so the card can quote it")
    func listRowPromptBodyReachesTheRow() throws {
        let context = try makeContext()
        let id = UUID()
        EntryCache.upsert(
            [try response(id: id, promptBody: "Take a picture of what he built")],
            into: context
        )

        let row = try #require(try context.fetch(FetchDescriptor<Entry>()).first)
        // Without this the timeline card renders with no quote until the entry is opened.
        #expect(row.promptBody == "Take a picture of what he built")
    }

    @Test("a response with no prompt_body does not blank a body already cached")
    func nilPromptBodyDoesNotBlankTheCache() throws {
        // The conditional write is the load-bearing part. A freeform entry legitimately has no
        // prompt, so nil means "nothing to say", never "erase what you have" — and a plain
        // assignment here would wipe the detail fetch's answer on the next list refresh.
        let context = try makeContext()
        let id = UUID()
        EntryCache.upsert([try response(id: id, promptBody: "the original sentence")], into: context)
        EntryCache.upsert([try response(id: id, promptBody: nil)], into: context)

        let row = try #require(try context.fetch(FetchDescriptor<Entry>()).first)
        #expect(row.promptBody == "the original sentence")
    }

    @Test("the detail prompt wins over prompt_body, so body and kind come off one response")
    func detailPromptWinsOverPromptBody() throws {
        let context = try makeContext()
        let id = UUID()
        EntryCache.upsert(
            [try response(id: id, prompt: "the detail sentence", promptBody: "the list sentence")],
            into: context
        )

        let row = try #require(try context.fetch(FetchDescriptor<Entry>()).first)
        // They are the same sentence in production. Preferring the one that travels with the
        // kind is what stops body and kind ever coming off different responses.
        #expect(row.promptBody == "the detail sentence")
        #expect(row.promptKind != nil)
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

    @Test("a photo deleted on another phone leaves this one")
    func mediaDeletedElsewhereIsMarked() throws {
        // Every response carrying an entry carries all of its live media, so absence from that
        // list is information rather than silence. Without acting on it the card keeps drawing a
        // picture that is gone from the archive — `GET /entries` omits deleted media instead of
        // returning it with a `deleted_at` the way `/sync` does.
        let context = try makeContext()
        let entryId = UUID()
        let kept = UUID()
        let removed = UUID()

        EntryCache.upsert(
            [try response(id: entryId, type: "photo", media: [mediaJSON(id: kept), mediaJSON(id: removed)])],
            into: context
        )
        #expect(try context.fetch(FetchDescriptor<Media>()).filter { $0.deletedAt == nil }.count == 2)

        // The same entry, now with one photo.
        EntryCache.upsert(
            [try response(id: entryId, type: "photo", media: [mediaJSON(id: kept)])],
            into: context
        )

        #expect(EntryCache.media(id: kept, in: context)?.deletedAt == nil)
        #expect(EntryCache.media(id: removed, in: context)?.deletedAt != nil)
        // Marked, never removed. A deletion the client cannot describe is one it cannot sync.
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == 2)
    }

    @Test("a photo still uploading from this phone is not mistaken for a deleted one")
    func inFlightMediaSurvivesAReconcile() throws {
        // A local row the server has not been told about yet is absent from every response by
        // definition. Marking it would throw away a photo that is still on its way.
        let context = try makeContext()
        let entryId = UUID()
        let staged = Media(entryId: entryId, kind: "photo", contentType: "image/jpeg", byteCount: 900)
        let uploading = Media(entryId: entryId, kind: "photo", contentType: "image/jpeg", byteCount: 900)
        uploading.state = .uploading
        context.insert(staged)
        context.insert(uploading)
        try context.save()

        EntryCache.upsertMedia([], entryId: entryId, into: context)

        #expect(staged.deletedAt == nil)
        #expect(uploading.deletedAt == nil)
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
