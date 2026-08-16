import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Phase 17 — structured extraction over entry bodies.
///
/// The assertion that matters most is `aSealedEntryIsNeverExtractedFrom`. A sealed letter is
/// written to be opened years from now; its contents leaking into tags that render on today's
/// timeline is the highest-consequence defect available here, and it would show the parent the
/// exact thing they deliberately locked.

// MARK: - Doubles

/// Records every call, so "the model was never asked" is assertable rather than assumed.
final class StubExtractor: EntryExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var _availability: ExtractionAvailability
    private var _result: ExtractedDetails
    private var _shouldThrow = false
    private var _bodiesSeen: [String] = []

    init(
        availability: ExtractionAvailability = .available,
        result: ExtractedDetails = ExtractedDetails(tags: ["beach"])
    ) {
        self._availability = availability
        self._result = result
    }

    /// **Every body the model was shown.** Empty means it was never asked — which is the whole
    /// assertion for the sealed case.
    var bodiesSeen: [String] { lock.lock(); defer { lock.unlock() }; return _bodiesSeen }
    var wasAsked: Bool { !bodiesSeen.isEmpty }

    func failNext() {
        lock.lock(); defer { lock.unlock() }
        _shouldThrow = true
    }

    func availability() async -> ExtractionAvailability {
        lock.withLock { _availability }
    }

    func extract(from body: String) async throws -> ExtractedDetails {
        // The throw happens *after* the lock is released, which is why the state comes out as a
        // tuple rather than the body throwing inside the closure. Unchanged from the paired
        // lock/unlock this replaces — `withLock` is the async-safe spelling of the same scope.
        let (shouldThrow, result) = lock.withLock {
            _bodiesSeen.append(body)
            return (_shouldThrow, _result)
        }
        if shouldThrow { throw APIError.transport("model failed") }
        return result
    }
}

private struct TestError: Error {}

@MainActor
@Suite("Structured extraction")
struct ExtractionTests {

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

    /// An entry in the local store, with the fields this phase cares about.
    @discardableResult
    private func makeEntry(
        in context: ModelContext,
        body: String? = "A long afternoon at the beach with Ada.",
        unlockAtAge: Int? = nil,
        extractedAt: Date? = nil,
        childId: UUID = UUID()
    ) -> Entry {
        let entry = Entry(
            id: UUID(),
            childId: childId,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            body: body,
            unlockAtAge: unlockAtAge
        )
        entry.extractedAt = extractedAt
        context.insert(entry)
        try? context.save()
        return entry
    }

    /// Answers `PATCH /entries/{id}` and records what was sent.
    private func patchPerformer(entryId: UUID) -> StubPerformer {
        let performer = StubPerformer()
        performer.on("/v1/entries/\(entryId.uuidString.lowercased())") { _ in
            let json = """
            {"id":"\(entryId.uuidString)","child_id":"\(UUID().uuidString)",
             "occurred_at":"2023-11-14T22:13:20Z","created_at":"2023-11-14T22:13:20Z",
             "updated_at":"2023-11-14T22:13:20Z","tags":[],"media":[],"media_count":0}
            """
            return (Data(json.utf8), 200)
        }
        return performer
    }

    // MARK: - The rule that must not break

    /// **Required break-the-code assertion.**
    @Test("A sealed entry is never extracted from")
    func aSealedEntryIsNeverExtractedFrom() async throws {
        let context = try makeContext()
        let entry = makeEntry(in: context, body: "For you at eighteen. I hope you still laugh like that.", unlockAtAge: 18)
        let extractor = StubExtractor()
        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)), context: context, extractor: extractor
        )

        let outcome = await queue.extract(entryId: entry.id)

        #expect(outcome == .skipped(.sealed))
        // The body was never shown to the model at all — not filtered afterwards, never read.
        #expect(extractor.wasAsked == false)
        #expect(entry.extractedAt == nil)
    }

    @Test("A sealed entry is refused before availability is even consulted")
    func sealIsCheckedBeforeAnythingElse() async throws {
        let context = try makeContext()
        // Available model, ordinary body — nothing else would stop this.
        let entry = makeEntry(in: context, unlockAtAge: 13)
        let extractor = StubExtractor(availability: .available)
        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)), context: context, extractor: extractor
        )

        #expect(await queue.extract(entryId: entry.id) == .skipped(.sealed))
        #expect(extractor.bodiesSeen.isEmpty)
    }

    // MARK: - The parent's words

    @Test("title and body are byte-identical before and after")
    func parentTextIsNeverTouched() async throws {
        let context = try makeContext()
        let original = "A long afternoon at the beach with Ada."
        let entry = makeEntry(in: context, body: original)
        entry.title = "The beach"
        try? context.save()

        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)),
            context: context,
            extractor: StubExtractor(result: ExtractedDetails(tags: ["seaside"], summary: "A beach day."))
        )
        await queue.extract(entryId: entry.id)

        #expect(entry.body == original)
        #expect(entry.title == "The beach")
    }

    // MARK: - Provenance

    @Test("Everything written carries source = device_ai")
    func everythingIsDeviceAI() throws {
        let changes = EntryChanges(
            tags: .set([EntryTagWrite(name: "beach", source: .deviceAI)])
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(data: try encoder.encode(changes), encoding: .utf8) ?? ""

        #expect(json.contains("\"source\":\"device_ai\""))
        #expect(json.contains("\"user\"") == false)
        // title and body are absent from the payload entirely — not null, absent.
        #expect(json.contains("title") == false)
        #expect(json.contains("body") == false)
    }

    @Test("A device_ai write sends no other field, so the parent's tags are left alone")
    func writeCarriesOnlyTags() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(
            data: try encoder.encode(
                EntryChanges(tags: .set([EntryTagWrite(name: "beach", source: .deviceAI)]))
            ),
            encoding: .utf8
        ) ?? ""

        // Exactly one top-level key. The server leaves a source absent from the payload alone,
        // which is what makes this incapable of touching a tag the parent typed.
        //
        // Decoded rather than string-compared: `JSONEncoder` gives no key-order guarantee, and an
        // assertion that depends on one fails for a reason that has nothing to do with the rule.
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(decoded?.keys.sorted() == ["tags"])
        let tags = decoded?["tags"] as? [[String: String]]
        #expect(tags == [["name": "beach", "source": "device_ai"]])
    }

    // MARK: - Degrading silently

    @Test("An unavailable model changes nothing and surfaces nothing")
    func unavailableDegradesSilently() async throws {
        let context = try makeContext()
        let entry = makeEntry(in: context)
        let extractor = StubExtractor(availability: .unavailable)
        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)), context: context, extractor: extractor
        )

        #expect(await queue.extract(entryId: entry.id) == .skipped(.unavailable))
        #expect(extractor.wasAsked == false)
        #expect(entry.extractedAt == nil)
        // Not stamped, so nothing is permanently closed off — a phone that qualifies later can
        // still do it. And no retry storm: one call, one answer, no loop.
    }

    @Test("A model failure leaves the row retryable and says nothing")
    func failureIsSilentAndRetryable() async throws {
        let context = try makeContext()
        let entry = makeEntry(in: context)
        let extractor = StubExtractor()
        extractor.failNext()
        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)), context: context, extractor: extractor
        )

        #expect(await queue.extract(entryId: entry.id) == .failed)
        #expect(entry.extractedAt == nil)
    }

    // MARK: - Extract once, never re-run

    @Test("An already-extracted entry is never extracted again")
    func neverRunsTwice() async throws {
        let context = try makeContext()
        let entry = makeEntry(in: context)
        let extractor = StubExtractor()
        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)), context: context, extractor: extractor
        )

        let first = await queue.extract(entryId: entry.id)
        #expect(first == .extracted(tagCount: 1))
        #expect(entry.extractedAt != nil)

        let second = await queue.extract(entryId: entry.id)
        #expect(second == .skipped(.alreadyExtracted))
        // The model was asked exactly once, ever. This is what makes a tag the parent deleted
        // impossible to resurrect — there is no second write to resurrect it.
        #expect(extractor.bodiesSeen.count == 1)
    }

    @Test("An entry the model had nothing to say about is still stamped")
    func emptyResultIsStillDone() async throws {
        let context = try makeContext()
        let entry = makeEntry(in: context)
        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)),
            context: context,
            extractor: StubExtractor(result: ExtractedDetails())
        )

        #expect(await queue.extract(entryId: entry.id) == .extracted(tagCount: 0))
        // Stamped, so it is not reconsidered on every launch for the life of the archive.
        #expect(entry.extractedAt != nil)
    }

    // MARK: - What actually reaches the archive

    /// **The whole result, routed through the queue rather than read back off the stub.**
    ///
    /// A model returns five fields; exactly one of them becomes durable. `people` and `place`
    /// join `tags` because they are the findable part, and `mood` and `summary` are produced and
    /// then deliberately dropped — this phase adds tags beside the parent's words and nothing
    /// else. Asserting that against the request the queue actually sent is the only way to see
    /// it; asking the stub what it was configured with proves nothing about any of it.
    @Test("A full result reaches the server as device_ai tags, and as nothing else")
    func aFullResultIsWrittenAsTagsOnly() async throws {
        let context = try makeContext()
        let entry = makeEntry(in: context)
        let performer = patchPerformer(entryId: entry.id)
        let queue = ExtractionQueue(
            api: client(performer),
            context: context,
            extractor: StubExtractor(
                result: ExtractedDetails(
                    people: ["Ada"], place: "the beach", mood: "delighted",
                    tags: ["sand", "sea"], summary: "An afternoon at the shore."
                )
            )
        )

        // Two tags, one person, one place — four names, under the limit of five.
        #expect(await queue.extract(entryId: entry.id) == .extracted(tagCount: 4))

        let body = try #require(performer.requests.last?.httpBody)
        let raw = try JSONSerialization.jsonObject(with: body)
        let payload = try #require(raw as? [String: Any])
        let tags = try #require(payload["tags"] as? [[String: String]])

        // Tags first, then people, then place — the model's own ordering survives.
        #expect(tags.compactMap { $0["name"] } == ["sand", "sea", "Ada", "the beach"])
        #expect(tags.allSatisfy { $0["source"] == "device_ai" })
        // Exactly one top-level key. A mood or a summary in this payload would be the model
        // writing prose into a permanent record beside the parent's own.
        #expect(payload.keys.sorted() == ["tags"])

        #expect(entry.extractedAt != nil, "stamped, so it is never re-run")
        #expect(entry.body == "A long afternoon at the beach with Ada.")
    }

    @Test("An entry with no body is skipped")
    func noBodyIsSkipped() async throws {
        let context = try makeContext()
        let entry = makeEntry(in: context, body: "   ")
        let extractor = StubExtractor()
        let queue = ExtractionQueue(
            api: client(patchPerformer(entryId: entry.id)), context: context, extractor: extractor
        )

        #expect(await queue.extract(entryId: entry.id) == .skipped(.noBody))
        #expect(extractor.wasAsked == false)
    }

    @Test("Pending never offers a sealed or already-extracted entry")
    func pendingExcludesSealedAndDone() throws {
        let context = try makeContext()
        let child = UUID()
        makeEntry(in: context, body: "Ordinary.", childId: child)
        makeEntry(in: context, body: "Sealed.", unlockAtAge: 18, childId: child)
        makeEntry(in: context, body: "Done.", extractedAt: Date(), childId: child)
        makeEntry(in: context, body: nil, childId: child)

        #expect(ExtractionQueue.pending(in: context, childId: child).count == 1)
    }

    /// **One store holds every child's rows, and extraction is not repeatable.** `extractedAt` is
    /// stamped once and never revisited, so an unscoped queue can spend a sibling's only pass on
    /// the wrong entry — and the tags it would have produced are not recoverable by reopening the
    /// app. This is the reason `pending` takes a child at all.
    @Test("Pending never offers another child's entry")
    func pendingIsScopedToOneChild() throws {
        let context = try makeContext()
        let mine = UUID()
        let sibling = UUID()
        let ours = makeEntry(in: context, body: "Ours.", childId: mine)
        makeEntry(in: context, body: "Theirs.", childId: sibling)

        let pending = ExtractionQueue.pending(in: context, childId: mine)

        #expect(pending.map(\.id) == [ours.id])
    }
}

// MARK: - The struct itself

@Suite("ExtractedDetails")
struct ExtractedDetailsTests {

    @Test("The tag count is bounded")
    func tagCountIsBounded() {
        let details = ExtractedDetails(tags: (1...20).map { "tag\($0)" })
        #expect(details.normalized().tags.count == ExtractedDetails.tagLimit)
        #expect(details.writableTagNames.count <= ExtractedDetails.tagLimit)
    }

    @Test("People and place become tags, still bounded")
    func peopleAndPlaceAreWritable() {
        let details = ExtractedDetails(
            people: ["Ada"], place: "the beach", tags: ["sand"]
        )
        let names = details.writableTagNames

        #expect(names.contains("Ada"))
        #expect(names.contains("the beach"))
        #expect(names.contains("sand"))
        #expect(names.count <= ExtractedDetails.tagLimit)
    }

    @Test("Blank and duplicate tags are dropped, order preserved")
    func normalizationCleansUp() {
        let details = ExtractedDetails(tags: ["beach", "  ", "Beach", "sand", "beach"])
        #expect(details.normalized().tags == ["beach", "sand"])
    }

    @Test("Empty strings become nil rather than empty values in the archive")
    func blanksBecomeNil() {
        let details = ExtractedDetails(place: "  ", mood: "", summary: " ").normalized()
        #expect(details.place == nil)
        #expect(details.mood == nil)
        #expect(details.summary == nil)
    }
}
