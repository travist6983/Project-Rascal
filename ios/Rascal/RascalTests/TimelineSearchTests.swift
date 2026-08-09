import Foundation
import SwiftData
import Testing

@testable import Rascal

/// `GET /entries?q=` — the surface that makes transcription observable.
///
/// The two rules worth guarding are both about *not* doing something: not issuing a request per
/// keystroke, and not letting a slow answer to an abandoned question land on top of a fast answer
/// to the current one. Both fail in the same direction — a search box that shows results for
/// something nobody typed — and neither is visible in a screenshot.
@MainActor
@Suite("Timeline search")
struct TimelineSearchTests {

    /// **The debounce is driven to zero and the model is awaited, never slept past.**
    ///
    /// A test that sleeps for a real debounce is a test whose result depends on how loaded the
    /// machine is, and this suite runs in parallel with forty others. Written that way first, it
    /// passed alone and failed every time in the full run — the tasks were simply starved past
    /// the sleep. `waitForInFlight()` is the fix: it settles the model rather than guessing when
    /// it will have settled.
    private func model(_ performer: StubPerformer, context: ModelContext, childId: UUID = UUID()) -> TimelineSearchModel {
        TimelineSearchModel(
            childId: childId, api: testClient(performer), context: context, debounce: .zero
        )
    }

    /// The `q` parameter of every `/entries` request, in order.
    private func queries(_ performer: StubPerformer) -> [String] {
        performer.requests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value
        }
    }

    private func cursors(_ performer: StubPerformer) -> [String?] {
        performer.requests
            .filter { $0.url?.path().contains("/entries") ?? false }
            .map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "cursor" }?.value
            }
    }

    // MARK: 11 — Debounce, and abandoning what is stale

    @Test("typing a word is one request, not one request per letter")
    func typingDebounces() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { _ in
            (pageJSON([entryJSON(id: UUID(), childId: child, occurredAt: Date())], cursor: nil), 200)
        }
        let subject = model(performer, context: context, childId: child)

        // Five keystrokes with no awaiting between them, which is what typing is. Each one
        // cancels the run the previous one started, so only the last survives to make a request.
        for prefix in ["b", "br", "bra", "brac", "brachio"] {
            subject.search(prefix)
        }
        await subject.waitForInFlight()

        #expect(queries(performer) == ["brachio"])
        #expect(subject.matchedQuery == "brachio")
    }

    // The other half of "cancels in-flight requests on query change" is below rather than here.
    // A version of it was written at this spot keyed on the stub's call count, and it was
    // meaningless: with the debounce driven to zero and no await between the two `search` calls,
    // the first run never issues a request at all — so the second query *was* call one, and the
    // test asserted the ordering of something that only happened once. Proving a request is
    // abandoned requires one to be genuinely outstanding, which is what the next test arranges.

    @Test("a request already in flight is abandoned, and an abandoned request writes nothing")
    func inFlightRequestsAreCancelled() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let current = UUID()
        let performer = StubPerformer()
        // Outstanding long enough to still be in flight when the next query arrives. The delay is
        // applied *after* the request is recorded, so the spin below is a fact rather than a wait.
        performer.delay = .milliseconds(200)
        performer.on("/entries") { count in
            // The abandoned request fails. That is the path the cancellation check was missing
            // from — the success path had one and the failure path did not, so a stale 500 wrote
            // a notice over results belonging to the query still on screen.
            count == 1
                ? (Data("{}".utf8), 500)
                : (pageJSON([entryJSON(id: current, childId: child, occurredAt: Date())], cursor: nil), 200)
        }
        let subject = model(performer, context: context, childId: child)

        subject.search("dinosaur")
        let abandoned = subject.currentRun
        // Spin until the request is genuinely outstanding. No wall clock: this waits on the thing
        // itself, so it cannot be starved into passing for the wrong reason.
        while performer.count(for: "/entries") == 0 { await Task.yield() }

        subject.search("pancakes")
        // The abandoned run is allowed to finish **completely** before anything is asserted, so
        // this is not a race that happens to resolve the right way.
        await abandoned?.value
        await subject.waitForInFlight()

        #expect(performer.count(for: "/entries") == 2)
        #expect(subject.matchedQuery == "pancakes")
        #expect(subject.resultIds == [current])
        // The abandoned 500 wrote neither of these.
        #expect(subject.notice == nil)
        #expect(subject.reachedEnd)
    }

    @Test("clearing the field forgets the results, the query, and the position in them")
    func clearingResets() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { _ in
            (pageJSON([entryJSON(id: UUID(), childId: child, occurredAt: Date())], cursor: "page-2"), 200)
        }
        let subject = model(performer, context: context, childId: child)

        subject.search("dinosaur")
        await subject.waitForInFlight()
        #expect(!subject.isEmpty)

        subject.search("   ")
        #expect(subject.isEmpty)
        #expect(subject.matchedQuery == nil)
        #expect(!subject.hasSearched)
        // No request at all for an empty query — an empty search is not a search.
        #expect(queries(performer) == ["dinosaur"])
    }

    // MARK: 12 — The server's keyset contract

    @Test("paging follows next_cursor, and stops when the server says there is no page after this")
    func pagingFollowsTheServersCursor() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { count in
            // Page one hands back a cursor; page two hands back null, which is the server saying
            // that was the last of them.
            (pageJSON(
                [entryJSON(id: UUID(), childId: child, occurredAt: Date())],
                cursor: count == 1 ? "rank-keyset-2" : nil
            ), 200)
        }
        let subject = model(performer, context: context, childId: child)

        subject.search("swimming")
        await subject.waitForInFlight()
        #expect(!subject.reachedEnd)

        await subject.loadMoreIfNeeded()

        // **The server's opaque cursor, sent back verbatim.** It encodes `(rank, occurred_at, id)`
        // — nothing on device can reconstruct rank, so a client that invented a window here would
        // silently skip or repeat rows.
        #expect(cursors(performer) == [nil, "rank-keyset-2"])
        #expect(subject.reachedEnd)
        #expect(subject.resultIds.count == 2)

        // And it stops. A third call has no cursor to follow and must not re-ask for page one.
        await subject.loadMoreIfNeeded()
        #expect(performer.count(for: "/entries") == 2)
    }

    @Test("a new query starts a new sequence of pages rather than continuing the old one")
    func aNewQueryDropsTheOldCursor() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { _ in
            (pageJSON([entryJSON(id: UUID(), childId: child, occurredAt: Date())], cursor: "page-2"), 200)
        }
        let subject = model(performer, context: context, childId: child)

        subject.search("dinosaur")
        await subject.waitForInFlight()
        subject.search("pancakes")
        await subject.waitForInFlight()

        // Both first pages, both with no cursor. Carrying one across would ask the server to
        // continue a ranking it is no longer computing — which the API answers `422`, by test.
        #expect(cursors(performer) == [nil, nil])
    }

    @Test("results keep the server's order, which is relevance and not date")
    func resultsKeepTheServersOrder() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        // Deliberately not in date order: the second is older, and the server ranked it first.
        let best = UUID()
        let older = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { _ in
            (pageJSON([
                entryJSON(id: best, childId: child, occurredAt: Date(timeIntervalSince1970: 1_600_000_000)),
                entryJSON(id: older, childId: child, occurredAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ], cursor: nil), 200)
        }
        let subject = model(performer, context: context, childId: child)

        subject.search("dinosaur")
        await subject.waitForInFlight()

        #expect(subject.resultIds == [best, older])
    }

    @Test("a failed search says so quietly and does not blank what is on screen")
    func aFailedSearchIsQuiet() async throws {
        let context = try inMemoryContext()
        let performer = StubPerformer()
        performer.on("/entries") { _ in (Data("{}".utf8), 500) }
        let subject = model(performer, context: context)

        subject.search("dinosaur")
        await subject.waitForInFlight()

        #expect(subject.notice != nil)
        #expect(subject.hasSearched)
    }

    // MARK: 13 — Why a row matched

    @Test("a result matched on a transcript shows the line of it that matched")
    func aTranscriptMatchSurfacesItsLine() throws {
        let context = try inMemoryContext()
        let entry = try cachedEntry(type: "audio", body: nil)
        context.insert(entry)
        let media = completeMedia(
            entryId: entry.id, kind: "audio", duration: 90,
            transcript: "we went to the park. and then the brachiosaurus ate the whole entire tree. "
                + "then we had lunch"
        )
        context.insert(media)
        try context.save()

        let card = EntryCardModel(entry: entry, media: [media], searchQuery: "brachiosaurus")

        #expect(card.searchMatch == "and then the brachiosaurus ate the whole entire tree")
        // And it is what the card sets, italic, because the words are the child's.
        #expect(card.bodyLine?.text == "and then the brachiosaurus ate the whole entire tree")
        #expect(card.bodyLine?.isQuote == true)
    }

    @Test("the matching line outranks the parent's own note, because it is why the row is here")
    func theMatchOutranksTheBody() throws {
        let context = try inMemoryContext()
        let entry = try cachedEntry(type: "audio", body: "bedtime, ages ago")
        context.insert(entry)
        let media = completeMedia(
            entryId: entry.id, kind: "audio",
            transcript: "there was a dinosaur in the garden"
        )
        context.insert(media)
        try context.save()

        let plain = EntryCardModel(entry: entry, media: [media])
        #expect(plain.bodyLine?.text == "bedtime, ages ago")

        let found = EntryCardModel(entry: entry, media: [media], searchQuery: "dinosaur")
        #expect(found.bodyLine?.text == "there was a dinosaur in the garden")
    }

    @Test("a query the client cannot match in the transcript explains nothing rather than guessing")
    func noMatchExplainsNothing() {
        // Postgres stems, so the server finds "ran" for "running". This cannot, and when it
        // cannot it says nothing — a missing explanation is a smaller wrong than a wrong one.
        #expect(EntryCardModel.matchingLine(
            query: "running", in: ["he ran all the way to the gate"]
        ) == nil)
        // Case and accents do not count as a difference.
        #expect(EntryCardModel.matchingLine(
            query: "CAFÉ", in: ["we went to the cafe"]
        ) == "we went to the cafe")
    }

    @Test("a sealed letter explains nothing about why it matched")
    func sealedResultsStaySealed() throws {
        let context = try inMemoryContext()
        let entry = try cachedEntry(type: "audio", body: nil, unlockAtAge: 18)
        context.insert(entry)
        let media = completeMedia(entryId: entry.id, kind: "audio", transcript: "the secret words")
        context.insert(media)
        try context.save()

        let card = EntryCardModel(entry: entry, media: [media], searchQuery: "secret")

        // Quoting the inside of a sealed letter in a list of search results would make the seal
        // decorative.
        #expect(card.searchMatch == nil)
        #expect(card.bodyLine == nil)
    }
}
