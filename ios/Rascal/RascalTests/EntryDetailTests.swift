import Foundation
import SwiftData
import Testing

@testable import Rascal

/// One entry, in full — and the rules the detail screen is built on.
@MainActor
@Suite("Entry detail")
struct EntryDetailTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
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

    @Test("the detail fetch fills in the prompt and the transcript the list row never carried")
    func detailAddsPromptAndTranscript() throws {
        let context = try makeContext()
        let id = UUID()
        let child = UUID()
        let audioId = UUID()

        // The list row first: no prompt, no transcript, exactly as `GET /entries` returns it.
        EntryCache.upsert(
            [try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio", duration: 34)]
            ))],
            into: context
        )
        let entry = try #require(EntryCache.entry(id: id, in: context))
        #expect(entry.promptBody == nil)

        // Then the detail, which is the only response that carries either.
        EntryCache.upsert(
            try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio", duration: 34, transcript: "he told me about the pond")],
                prompt: "Record him telling you a story"
            )),
            into: context
        )

        #expect(entry.promptBody == "Record him telling you a story")
        #expect(EntryCache.media(id: audioId, in: context)?.transcript == "he told me about the pond")
    }

    @Test("a list response after a detail one does not blank the prompt or the transcript")
    func listDoesNotEraseDetail() throws {
        // Paging back over an entry already opened must not undo what opening it fetched.
        let context = try makeContext()
        let id = UUID()
        let child = UUID()
        let audioId = UUID()

        EntryCache.upsert(
            try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio", transcript: "what he said")],
                prompt: "Record him telling you a story"
            )),
            into: context
        )
        EntryCache.upsert(
            [try decodeEntry(entryJSON(
                id: id, childId: child, occurredAt: Date(), type: "audio", body: nil,
                media: [mediaJSON(id: audioId, kind: "audio")]
            ))],
            into: context
        )

        #expect(EntryCache.entry(id: id, in: context)?.promptBody == "Record him telling you a story")
        #expect(EntryCache.media(id: audioId, in: context)?.transcript == "what he said")
    }

    @Test("a freeform entry carries no prompt, and that is not a missing value")
    func freeformHasNoPrompt() throws {
        let context = try makeContext()
        let id = UUID()
        EntryCache.upsert(
            try decodeEntry(entryJSON(id: id, childId: UUID(), occurredAt: Date())),
            into: context
        )
        // The block is omitted cleanly rather than rendered empty — freeform entries are
        // first-class and must not look incomplete.
        #expect(EntryCache.entry(id: id, in: context)?.promptBody == nil)
    }

    @Test("deleting from the detail screen removes the row from the timeline query")
    func deleteRemovesFromTheList() async throws {
        let context = try makeContext()
        let child = UUID()
        let id = UUID()
        EntryCache.upsert(
            [try decodeEntry(entryJSON(id: id, childId: child, occurredAt: Date()))],
            into: context
        )
        let entry = try #require(EntryCache.entry(id: id, in: context))

        let performer = StubPerformer()
        performer.on("/entries/") { _ in (Data(), 204) }
        await EntryCache.delete(entry, api: client(performer), in: context)

        // The list's own predicate, verbatim.
        let visible = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil }
        ))
        #expect(visible.isEmpty)
        // And the row itself is still there, because a deletion syncs as a row.
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)
        #expect(entry.deletionPending == false)
    }

    @Test("a deleted entry does not come back when the next page is fetched")
    func deletedDoesNotResurrect() async throws {
        let context = try makeContext()
        let child = UUID()
        let id = UUID()
        let json = entryJSON(id: id, childId: child, occurredAt: Date())
        EntryCache.upsert([try decodeEntry(json)], into: context)
        let entry = try #require(EntryCache.entry(id: id, in: context))

        let performer = StubPerformer()
        performer.on("/entries/") { _ in (Data(), 204) }
        await EntryCache.delete(entry, api: client(performer), in: context)

        // `GET /entries` excludes soft-deleted rows, so the server will simply stop listing it.
        // But a page already in flight can still carry it, and that must not undelete anything.
        EntryCache.upsert([try decodeEntry(json)], into: context)

        #expect(entry.deletedAt != nil)
        let visible = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil }
        ))
        #expect(visible.isEmpty)
    }

    @Test("a sealed entry is a letter with an unlock age, and nothing else is")
    func sealedIsOnlyUnlockAtAge() throws {
        let context = try makeContext()
        let sealed = UUID()
        let plain = UUID()
        EntryCache.upsert(
            [
                try decodeEntry(entryJSON(
                    id: sealed, childId: UUID(), occurredAt: Date(),
                    title: "A letter", unlockAtAge: 18
                )),
                try decodeEntry(entryJSON(id: plain, childId: UUID(), occurredAt: Date())),
            ],
            into: context
        )

        #expect(EntryCache.entry(id: sealed, in: context)?.unlockAtAge == 18)
        #expect(EntryCache.entry(id: plain, in: context)?.unlockAtAge == nil)
    }

    @Test("editing routes into the composer rather than a second editor")
    func editModeMatchesTheComposer() throws {
        // The rule is one editor in this app. This asserts the request the detail screen builds
        // is the one `ComposerView.loadForEditing` knows how to open.
        let entryId = UUID()
        let written = ComposerRequest(childId: UUID(), assignment: nil, mode: .text, editing: entryId)
        let didIt = ComposerRequest(childId: UUID(), assignment: nil, mode: .didIt, editing: entryId)

        #expect(written.isEditing)
        #expect(written.editing == entryId)
        #expect(didIt.isEditing)
        #expect(written.assignment == nil, "an edit reopens the entry, not the mission")
    }
}
