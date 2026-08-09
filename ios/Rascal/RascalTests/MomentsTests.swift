import Foundation
import SwiftData
import Testing

@testable import Rascal

/// On This Day, in both of the shapes the server answers with.
@MainActor
@Suite("Moments")
struct MomentsTests {

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

    private func groupedResponse(child: UUID) -> Data {
        let oneYear = entryJSON(
            id: UUID(), childId: child,
            occurredAt: Date(timeIntervalSince1970: 1_723_113_600),
            type: "photo", body: "the paddling pool", media: [mediaJSON()]
        )
        let threeYears = entryJSON(
            id: UUID(), childId: child,
            occurredAt: Date(timeIntervalSince1970: 1_660_041_600),
            type: "text", body: "he learned the word 'actually'"
        )
        return Data("""
        {"date":"2026-08-08","fallback":null,
         "groups":[{"years_ago":1,"entries":[\(oneYear)]},
                   {"years_ago":3,"entries":[\(threeYears)]}],
         "entries":[]}
        """.utf8)
    }

    private func fallbackResponse(child: UUID) -> Data {
        let random = entryJSON(
            id: UUID(), childId: child,
            occurredAt: Date(timeIntervalSince1970: 1_690_000_000),
            type: "text", body: "he called it a hangaburger"
        )
        return Data("""
        {"date":"2026-08-08","fallback":"random","groups":[],"entries":[\(random)]}
        """.utf8)
    }

    @Test("a grouped answer becomes one section per year, newest year first")
    func rendersGroups() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        let body = groupedResponse(child: child)
        performer.on("/moments") { _ in (body, 200) }

        let model = MomentsModel(childId: child, api: client(performer), context: context)
        await model.start()

        #expect(model.isFallback == false)
        #expect(model.date == "2026-08-08")
        #expect(model.sections.map(\.title) == ["1 year ago", "3 years ago"])
        #expect(model.sections.first?.cards.count == 1)
        // The photo section has a cover for its throwback card; the written one has none, and
        // its card renders on the gradient alone rather than as a grey box.
        #expect(model.sections.first?.cover != nil)
        #expect(model.sections.last?.cover == nil)
    }

    @Test("the warm redirect renders memories rather than a void")
    func rendersFallback() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        let body = fallbackResponse(child: child)
        performer.on("/moments") { _ in (body, 200) }

        let model = MomentsModel(childId: child, api: client(performer), context: context)
        await model.start()

        #expect(model.isFallback)
        #expect(model.sections.count == 1)
        #expect(model.sections.first?.cards.count == 1)
        #expect(model.sections.first?.cards.first?.preview == "he called it a hangaburger")
    }

    @Test("memories are cached, so the same row is shared with the timeline")
    func cachesTheEntries() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        let body = groupedResponse(child: child)
        performer.on("/moments") { _ in (body, 200) }

        await MomentsModel(childId: child, api: client(performer), context: context).start()

        // Two entries and one photo, in the one store the timeline reads from.
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Media>()) == 1)
    }

    @Test("a memory deleted here drops out of its section on the next load")
    func deletedMemoryLeaves() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        let body = groupedResponse(child: child)
        performer.on("/moments") { _ in (body, 200) }
        performer.on("/entries/") { _ in (Data(), 204) }

        let api = client(performer)
        let model = MomentsModel(childId: child, api: api, context: context)
        await model.start()

        let victim = try #require(model.sections.first?.cards.first?.id)
        let entry = try #require(EntryCache.entry(id: victim, in: context))
        await EntryCache.delete(entry, api: api, in: context)

        await model.load()

        // The server has not caught up — it still lists the row — and the client still must not
        // show a card for something the parent deleted.
        #expect(!model.sections.flatMap(\.cards).contains { $0.id == victim })
    }

    @Test("an empty archive gets an invitation, not an accusation")
    func handlesNothingAtAll() async throws {
        let context = try makeContext()
        let performer = StubPerformer()
        let empty = Data(#"{"date":"2026-08-08","fallback":"random","groups":[],"entries":[]}"#.utf8)
        performer.on("/moments") { _ in (empty, 200) }

        let model = MomentsModel(childId: UUID(), api: client(performer), context: context)
        await model.start()

        #expect(model.hasLoaded)
        #expect(model.sections.isEmpty, "the screen shows its own empty state rather than a blank section")
        #expect(model.notice == nil, "nothing failed, so nothing is reported as a failure")
    }

    @Test("a failure leaves a quiet note and never an empty screen pretending to be an answer")
    func handlesFailure() async throws {
        let context = try makeContext()
        let performer = StubPerformer()
        let boom = Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8)
        performer.on("/moments") { _ in (boom, 500) }

        let model = MomentsModel(childId: UUID(), api: client(performer), context: context)
        await model.start()

        #expect(model.hasLoaded)
        #expect(model.notice != nil)
        #expect(model.isFallback == false)
    }

    @Test("years-ago headings are plural except the first")
    func headingsReadNaturally() {
        #expect(MomentGroupResponse(yearsAgo: 1, entries: []).title == "1 year ago")
        #expect(MomentGroupResponse(yearsAgo: 6, entries: []).title == "6 years ago")
    }
}
