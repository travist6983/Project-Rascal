import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The sweep that re-sends entries the server never acknowledged.
///
/// This existed only as a comment for a while — `ComposerView` said "will retry on next
/// foreground" and nothing did. These tests exist so that cannot silently become true again.

/// Built on the main actor and captured as `Data`, because the stub's closures are
/// `@Sendable` and cannot reach back into an actor-isolated helper.
private func entryResponse(id: UUID, childId: UUID, occurredAt: Date) -> Data {
    let iso = ISO8601Formatters.string(from: occurredAt)
    return Data("""
    {"id":"\(id.uuidString)","child_id":"\(childId.uuidString)",
     "assignment_id":null,"occurred_at":"\(iso)","created_at":"\(iso)",
     "updated_at":"\(iso)","deleted_at":null,"title":null,"body":"x",
     "entry_type":"text","child_age_months":62,"unlock_at_age":null}
    """.utf8)
}

@MainActor
@Suite("Entry sync")
struct EntrySyncTests {

    /// An in-memory store, so nothing touches the simulator's real container.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([Entry.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    @Test("a pending entry is re-sent and becomes synced")
    func sweepsPending() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "he said hangaburger")
        context.insert(entry)

        let performer = StubPerformer()
        let ok = entryResponse(id: entry.id, childId: entry.childId, occurredAt: entry.occurredAt)
        performer.on("/entries") { _ in (ok, 201) }

        let sync = EntrySync(api: client(performer), context: context)
        #expect(sync.unsyncedCount() == 1)

        let synced = await sync.sweep()
        #expect(synced == 1)
        #expect(entry.sync == .synced)
        #expect(sync.unsyncedCount() == 0)
    }

    @Test("a failed entry is retried, not abandoned")
    func retriesFailed() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "written offline")
        entry.sync = .failed
        context.insert(entry)

        let performer = StubPerformer()
        let ok = entryResponse(id: entry.id, childId: entry.childId, occurredAt: entry.occurredAt)
        performer.on("/entries") { _ in (ok, 201) }

        let synced = await EntrySync(api: client(performer), context: context).sweep()
        #expect(synced == 1, "a failure is a network fact, not a verdict about the entry")
        #expect(entry.sync == .synced)
    }

    @Test("the same idempotency key is presented on every attempt")
    func stableIdempotencyKey() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "retried")
        entry.sync = .failed
        context.insert(entry)

        let performer = StubPerformer()
        // Fail once, then succeed — the server must see one key across both attempts, or the
        // replay creates a second row instead of returning the original.
        let ok = entryResponse(id: entry.id, childId: entry.childId, occurredAt: entry.occurredAt)
        performer.on("/entries") { n in
            n == 1 ? (Data(#"{"error":{"code":"internal_error","message":"boom","field":null}}"#.utf8), 500)
                   : (ok, 201)
        }

        let sync = EntrySync(api: client(performer), context: context)
        await sync.sweep()
        #expect(entry.sync == .failed)
        await sync.sweep()
        #expect(entry.sync == .synced)

        let keys = Set(performer.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") })
        #expect(keys.count == 1, "a changing key would turn a retry into a duplicate entry")
    }

    @Test("an expired assignment drops the link and keeps the entry")
    func expiredAssignmentKeepsTheEntry() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), assignmentId: UUID(), occurredAt: Date(), body: "late")
        context.insert(entry)

        let performer = StubPerformer()
        performer.on("/entries") { _ in
            (Data(#"{"error":{"code":"assignment_expired","message":"too late","field":null}}"#.utf8), 409)
        }

        await EntrySync(api: client(performer), context: context).sweep()
        // The archive matters more than the bookkeeping: the writing is kept, the link is not.
        #expect(entry.assignmentId == nil)
        #expect(entry.sync == .pending, "it should go out again as a freeform entry")
    }

    @Test("a synced entry is never re-sent")
    func skipsSynced() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "already there")
        entry.sync = .synced
        context.insert(entry)

        let performer = StubPerformer()
        let ok = entryResponse(id: entry.id, childId: entry.childId, occurredAt: entry.occurredAt)
        performer.on("/entries") { _ in (ok, 201) }

        let synced = await EntrySync(api: client(performer), context: context).sweep()
        #expect(synced == 0)
        #expect(performer.count(for: "entries") == 0)
    }

    @Test("a soft-deleted entry is never re-sent")
    func skipsDeleted() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "removed")
        entry.deletedAt = Date()
        context.insert(entry)

        let performer = StubPerformer()
        let ok = entryResponse(id: entry.id, childId: entry.childId, occurredAt: entry.occurredAt)
        performer.on("/entries") { _ in (ok, 201) }

        _ = await EntrySync(api: client(performer), context: context).sweep()
        #expect(performer.count(for: "entries") == 0, "resurrecting a deleted entry is a defect")
    }

    @Test("offline leaves the entry intact for the next attempt")
    func offlineKeepsTheWork() async throws {
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "on a plane")
        context.insert(entry)

        let performer = StubPerformer()
        performer.on("/entries") { _ in (Data(), 503) }

        let synced = await EntrySync(api: client(performer), context: context).sweep()
        #expect(synced == 0)
        #expect(entry.sync == .failed)
        #expect(entry.body == "on a plane", "the writing survives regardless")
        // Still outstanding, so the next foreground picks it up.
        #expect(EntrySync(api: client(performer), context: context).unsyncedCount() == 1)
    }
}
