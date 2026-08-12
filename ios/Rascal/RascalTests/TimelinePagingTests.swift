import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Paging, and the states around its edges.
///
/// The rule has two halves and both are load bearing: the first request of a run is seeded from
/// the bottom of the cache, and every request after it follows the server's `next_cursor`. These
/// assert each half does its job — that a warm cache pages on from its own floor, and that a page
/// made entirely of rows already held still advances, because a keyset position advances even
/// when the floor does not.
@MainActor
@Suite("Timeline paging")
struct TimelinePagingTests {

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

    /// Two pages then a stop, driven by how many times `/entries` has been asked.
    private func pagedPerformer(child: UUID) -> StubPerformer {
        let performer = StubPerformer()
        let first = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: Date(timeIntervalSince1970: 1_700_000_000))],
            cursor: "cursor-one"
        )
        let second = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: Date(timeIntervalSince1970: 1_600_000_000))],
            cursor: nil
        )
        performer.on("/entries") { hit in (hit == 1 ? first : second, 200) }
        return performer
    }

    private func query(_ performer: StubPerformer, _ name: String) -> [String?] {
        performer.requests
            .filter { $0.url?.path().contains("/entries") ?? false }
            .map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == name }?.value
            }
    }

    private func befores(_ performer: StubPerformer) -> [String?] { query(performer, "before") }
    private func cursors(_ performer: StubPerformer) -> [String?] { query(performer, "cursor") }

    @Test("the first page asks for no window at all")
    func firstPageTakesNoWindow() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()

        #expect(befores(performer) == [nil])
        #expect(cursors(performer) == [nil])
        #expect(model.hasLoaded)
        #expect(model.reachedEnd == false, "the server offered another page")
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)
    }

    @Test("the next page asks for everything older than the oldest row on screen")
    func nextPageSeedsFromTheCache() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()

        let asked = befores(performer)
        #expect(asked.count == 2)
        #expect(asked[0] == nil)
        // One second past the oldest cached row: `before` is exclusive and two entries can
        // share an instant, so a boundary drawn exactly at the oldest row can skip its twin.
        let window = try #require(asked[1].flatMap(ISO8601Formatters.parse))
        #expect(abs(window.timeIntervalSince1970 - 1_700_000_001) < 1)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 2)
    }

    @Test("a page the server marks as the last one stops paging for good")
    func lastPageStops() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()
        #expect(model.reachedEnd)

        // The last card reappears every time the list settles; it must not turn into a loop.
        await model.loadMoreIfNeeded()
        await model.loadMoreIfNeeded()

        #expect(performer.count(for: "/entries") == 2)
    }

    @Test("an empty first page is a finished, empty archive rather than a spinner")
    func emptyFirstPage() async throws {
        let context = try makeContext()
        let performer = StubPerformer()
        let empty = pageJSON([], cursor: nil)
        performer.on("/entries") { _ in (empty, 200) }

        let model = TimelineModel(childId: UUID(), api: client(performer), context: context)
        await model.start()

        #expect(model.hasLoaded, "nothing fetched yet and nothing in the archive must not look the same")
        #expect(model.reachedEnd)
        #expect(model.notice == nil)
        await model.loadMoreIfNeeded()
        #expect(performer.count(for: "/entries") == 1)
    }

    @Test("changing the filter restarts paging rather than carrying a window across lists")
    func filterResetsPaging() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = pagedPerformer(child: child)

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.apply(.photo)

        // A position belongs to one list. Carrying it into another would page the photo filter
        // from somewhere the unfiltered one established.
        #expect(befores(performer) == [nil, nil])
        #expect(cursors(performer) == [nil, nil])
        let types = performer.requests.compactMap { request -> String? in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "type" }?.value
        }
        #expect(types == ["photo"])
    }

    @Test("a warm cache pages on from its own floor, not from where page one ended")
    func warmCachePagesOnward() async throws {
        // The defect a device found. Reopen the app with many pages already cached and the
        // page-one position asks for rows the cache already holds: no new card appears, nothing
        // triggers again, and the timeline stops at the bottom of the cache with years of
        // archive still unfetched. Seeding from the cache's own floor is the fix.
        let context = try makeContext()
        let child = UUID()
        let floor = Date(timeIntervalSince1970: 1_650_000_000)

        EntryCache.upsert(
            try (0..<10).map { index in
                try decodeEntry(entryJSON(
                    id: UUID(), childId: child,
                    occurredAt: floor.addingTimeInterval(Double(index) * 86_400)
                ))
            },
            into: context
        )

        let performer = pagedPerformer(child: child)
        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()

        let asked = befores(performer)
        let window = try #require(asked.last.flatMap { $0 }.flatMap(ISO8601Formatters.parse))
        #expect(
            abs(window.timeIntervalSince(floor) - 1) < 1,
            "the request must be older than everything on screen, not older than page one"
        )
    }

    @Test("a whole page of entries sharing one instant does not stall paging")
    func advancesPastATieEvenWhenTheFloorDoesNot() async throws {
        // A bulk import of photos with no EXIF date gives every entry the same `occurred_at`.
        // Seeding from the cache floor cannot get past that on its own: `before` is exclusive
        // and compares only `occurred_at`, so the page comes back full of rows already held, the
        // floor does not move, and an earlier version of this concluded the archive had ended —
        // hiding everything older until the app was relaunched. The cursor is a keyset position
        // on `(occurred_at, id)`, so it advances even when the floor cannot.
        let context = try makeContext()
        let child = UUID()
        let tie = Date(timeIntervalSince1970: 1_700_000_000)
        let stuck = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let performer = StubPerformer()
        let sameRow = pageJSON(
            [entryJSON(id: stuck, childId: child, occurredAt: tie)],
            cursor: "past-the-tie"
        )
        let older = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: Date(timeIntervalSince1970: 1_600_000_000))],
            cursor: nil
        )
        performer.on("/entries") { hit in (hit <= 2 ? sameRow : older, 200) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()
        #expect(model.reachedEnd == false, "the server said there was more, and there was")

        await model.loadMoreIfNeeded()

        #expect(cursors(performer) == [nil, nil, "past-the-tie"])
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 2, "it got past the tie")
        #expect(model.reachedEnd)
    }

    @Test("an entry backdated past the archive does not strand everything above it")
    func unsyncedFloorIsNotAPosition() async throws {
        // Someone scans a photo from 1990 and files it on the day it was taken, offline. It is
        // now the oldest row in the cache — but it is not a position in the server's ordering,
        // because the server has never seen it. Seeding from it asks for rows older than 1990,
        // gets nothing, and concludes the archive has ended, stranding every page between the
        // last one fetched and 1990.
        let context = try makeContext()
        let child = UUID()
        let recent = Date(timeIntervalSince1970: 1_700_000_000)

        let performer = StubPerformer()
        let first = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: recent)],
            cursor: "cursor-one"
        )
        let older = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: recent.addingTimeInterval(-86_400))],
            cursor: nil
        )
        performer.on("/entries") { hit in (hit == 1 ? first : older, 200) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()

        // The scanned photo, written locally and not yet pushed.
        let scanned = Entry(
            childId: child,
            occurredAt: Date(timeIntervalSince1970: 631_152_000),  // 1990-01-01
            body: "scanned from the album"
        )
        context.insert(scanned)
        try context.save()

        await model.loadMoreIfNeeded()

        let window = try #require(befores(performer).last.flatMap { $0 }.flatMap(ISO8601Formatters.parse))
        #expect(
            window > Date(timeIntervalSince1970: 1_600_000_000),
            "the seed must come from a row the server has actually given us, not from a local one"
        )
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 3, "the next page still arrived")
    }

    @Test("a refresh re-seeds from the cache rather than resuming where paging had reached")
    func refreshResetsTheContinuation() async throws {
        // Pull-to-refresh re-reads page one. If it left the continuation in place, the next
        // `loadMore` would resume from deep in the archive and skip everything between.
        let context = try makeContext()
        let child = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // A server with no end: every page offers another, so nothing stops on its own.
        let pages: [Data] = (0..<6).map { index in
            pageJSON(
                [entryJSON(
                    id: UUID(), childId: child,
                    occurredAt: base.addingTimeInterval(-Double(index) * 86_400)
                )],
                cursor: "c\(index)"
            )
        }
        let performer = StubPerformer()
        performer.on("/entries") { hit in (pages[min(hit - 1, pages.count - 1)], 200) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()
        #expect(cursors(performer).last ?? nil == nil, "the seed request carries no cursor")

        await model.refresh()
        await model.loadMoreIfNeeded()

        // Four requests: page one, a seed, page one again, another seed. No cursor anywhere,
        // because a refresh puts paging back at the top.
        #expect(cursors(performer) == [nil, nil, nil, nil])
        #expect(befores(performer).filter { $0 != nil }.count == 2)
    }

    @Test("a page that fails leaves a quiet note and keeps whatever is already cached")
    func failureKeepsTheCache() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        let good = pageJSON(
            [entryJSON(id: UUID(), childId: child, occurredAt: Date())],
            cursor: "cursor-one"
        )
        let boom = Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8)
        performer.on("/entries") { hit in hit == 1 ? (good, 200) : (boom, 500) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.start()
        await model.loadMoreIfNeeded()

        #expect(model.notice != nil)
        // The archive is already on screen. A failed refetch must never blank it.
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)
    }

    @Test("a locally created entry is in the timeline before the server has heard of it")
    func localEntryAppearsImmediately() async throws {
        let context = try makeContext()
        let child = UUID()
        let local = Entry(childId: child, occurredAt: Date(), body: "written on a train")
        context.insert(local)
        try context.save()

        let performer = StubPerformer()
        let empty = pageJSON([], cursor: nil)
        performer.on("/entries") { _ in (empty, 200) }
        await TimelineModel(childId: child, api: client(performer), context: context).start()

        // The list's own predicate. Whether the server has heard about it is a fact about the
        // network, not about the archive.
        let visible = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil }
        ))
        #expect(visible.count == 1)
        #expect(visible.first?.sync == .pending)
    }

    @Test("a backdated entry sorts by when it happened, not by when it was written")
    func sortsByOccurredAt() async throws {
        let context = try makeContext()
        let child = UUID()
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let longAgo = Date(timeIntervalSince1970: 1_500_000_000)

        // A 2017 photo, added tonight. `created_at` is now; `occurred_at` is 2017.
        let performer = StubPerformer()
        let page = pageJSON(
            [
                entryJSON(id: UUID(), childId: child, occurredAt: now, body: "tonight"),
                entryJSON(
                    id: UUID(), childId: child, occurredAt: longAgo, createdAt: now,
                    body: "a photo from years ago, imported tonight"
                ),
            ],
            cursor: nil
        )
        performer.on("/entries") { _ in (page, 200) }
        await TimelineModel(childId: child, api: client(performer), context: context).start()

        let ordered = try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.childId == child && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        ))
        #expect(ordered.first?.body == "tonight")
        #expect(ordered.last?.body == "a photo from years ago, imported tonight")
        // Both were written at the same moment. Only `occurred_at` separates them.
        #expect(ordered.allSatisfy { abs($0.createdAt.timeIntervalSince(now)) < 1 })
    }
}

// MARK: - A filter the server cannot express

/// A page holding one ordinary entry — nothing sealed.
///
/// Free rather than a suite member because `StubPerformer`'s rule closures are `@Sendable` and
/// nonisolated, and cannot reach a `@MainActor` method. Same reason the fixtures are free.
func ordinaryPage(child: UUID, at seconds: TimeInterval, cursor: String?) -> Data {
    pageJSON(
        [entryJSON(id: UUID(), childId: child, occurredAt: Date(timeIntervalSince1970: seconds))],
        cursor: cursor
    )
}


/// Sealed is `unlock_at_age`, not an `entry_type`, so there is no `?type=` for it — it goes on the
/// wire as `?sealed=true`. That parameter is new; before it, the client asked for the whole archive
/// and narrowed locally, which made paging a different problem because **a page that adds no
/// visible card also adds nothing to trigger the next one**. These covered the loop that fixed it
/// and now cover the filter that replaced the loop.
@MainActor
@Suite("Timeline paging under the sealed filter")
struct SealedFilterPagingTests {

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

    @Test("the sealed filter sends no type parameter, because there is none to send")
    func sendsNoTypeParameter() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { _ in (ordinaryPage(child: child, at: 1_700_000_000, cursor: nil), 200) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.apply(.sealed)

        let types = performer.requests
            .filter { $0.url?.path().contains("/entries") ?? false }
            .map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "type" }?.value
            }
        // Still no `?type=` — sealing is not an entry type. What changed is that it is not
        // *unexpressible* either: it goes as `?sealed=true`, which the message below used to
        // deny outright.
        #expect(types.allSatisfy { $0 == nil }, "sealing is not an entry_type")
    }

    /// **The bug this change nearly shipped, pinned.**
    ///
    /// Page two re-seeds from the cache rather than from page one's cursor. While the Sealed chip
    /// narrowed locally the request was unfiltered, so the right seed was the oldest cached row of
    /// *any* kind. With `?sealed=true` that seed is wrong in a way nothing on screen would show:
    /// the oldest cached row can be years older than the oldest cached *letter*, so page two asks
    /// for letters older than that and every letter in between is skipped, on a list that still
    /// looks complete.
    ///
    /// Browse All down to 2019, switch to Sealed, scroll. The seed must be the oldest cached
    /// letter, not the oldest cached entry.
    @Test("the sealed seed is the oldest cached letter, not the oldest cached entry")
    func sealedSeedIgnoresUnsealedCacheDepth() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()

        // A warm cache from an earlier All browse: one ancient ordinary entry, and a letter that
        // is far newer. Both already on the server.
        let ancient = Date(timeIntervalSince1970: 1_100_000_000)   // ~2004
        let letter = Date(timeIntervalSince1970: 1_700_000_000)    // ~2023
        EntryCache.upsert(
            [
                try decodeEntry(entryJSON(id: UUID(), childId: child, occurredAt: ancient)),
                try decodeEntry(entryJSON(
                    id: UUID(), childId: child, occurredAt: letter, unlockAtAge: 18
                )),
            ],
            into: context
        )

        // Page one adds no rows but leaves the list open, so the next load has to seed from the
        // cache — which is exactly the path that was reading the wrong row. (`loadFirstPage`
        // clears the continuation regardless of what page one returned, by design.)
        performer.on("/entries") { _ in (pageJSON([], cursor: "c1"), 200) }
        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.apply(.sealed)
        await model.loadMoreIfNeeded()

        let before = performer.requests
            .compactMap { $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) } }
            .compactMap { $0.queryItems?.first { $0.name == "before" }?.value }
            .last
        let seed = try #require(before, "page two must seed from somewhere")
        let seeded = try #require(ISO8601Formatters.parse(seed))

        // The letter's own timestamp (plus the one-second nudge), not the 2004 entry's.
        #expect(
            abs(seeded.timeIntervalSince(letter)) < 5,
            "seeded from \(seeded) — the oldest cached entry, not the oldest cached letter"
        )
        #expect(seeded.timeIntervalSince(ancient) > 60 * 60 * 24 * 365, "seeded years too early")
    }

    /// **Two tests were deleted here, for the same reason as the budget below.**
    ///
    /// `drainsUntilSomethingMatches` and `stopsAtTheEndOfTheArchive` each built an archive whose
    /// pages return rows the filter does not match — the situation the drain loop existed to walk
    /// through. `?sealed=true` makes that situation unreachable: the server returns letters and
    /// only letters, so a non-empty page is a page that draws and an empty one is the end.

    /// **Deleted with the budget it asserted, and the reason is the premise, not the number.**
    ///
    /// This test built "an archive that never runs out and never matches" — every page returning
    /// an ordinary entry plus another cursor — and asserted the loop stopped after ten. Under
    /// `?sealed=true` that archive cannot exist: the server returns only sealed rows, so a page
    /// that comes back non-empty is a page of letters and every one of them draws. A page with no
    /// letters left comes back empty and ends the paging.
    ///
    /// It was not telling us the budget still mattered; it was describing the shape of the
    /// workaround. `sealedPagesAreAllSealedAndNeverRepeat` below is what replaced it.

    /// **The test the phase brief asks for, and the one thing about this change that is easy to
    /// get wrong.**
    ///
    /// The paging seed used to stay unfiltered on purpose: seeding from the oldest *sealed* row
    /// would have stranded every ordinary entry between it and the present. With a server filter
    /// that reasoning no longer applies — every page is letters and only letters — but "no longer
    /// applies" is a claim worth pinning rather than asserting in a comment.
    ///
    /// Three pages, following the server's cursors. Every row sealed, and no row twice.
    @Test("a sealed list pages across three pages, all sealed and none repeated")
    func sealedPagesAreAllSealedAndNeverRepeat() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()

        // Three pages of letters, oldest-ward, the third ending the list with a null cursor.
        // Ids are fixed so a repeat is detectable rather than merely unlikely.
        let ids = (0..<6).map { _ in UUID() }
        performer.on("/entries") { hit in
            let slice: [UUID]
            let cursor: String?
            switch hit {
            case 1: slice = Array(ids[0..<2]); cursor = "c1"
            case 2: slice = Array(ids[2..<4]); cursor = "c2"
            default: slice = Array(ids[4..<6]); cursor = nil
            }
            let rows = slice.enumerated().map { index, id in
                entryJSON(
                    id: id,
                    childId: child,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(hit * 10 + index) * 1_000),
                    unlockAtAge: 18
                )
            }
            return (pageJSON(rows, cursor: cursor), 200)
        }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.apply(.sealed)
        await model.loadMoreIfNeeded()
        await model.loadMoreIfNeeded()

        // The filter went on the wire on every page, including the cursor pages — a filter that
        // is dropped after page one is how a "sealed" list quietly becomes the whole archive.
        let urls = performer.requests
            .compactMap { $0.url?.absoluteString }
            .filter { $0.contains("/entries") }
        #expect(urls.count == 3, "three pages, one request each — no drain loop")
        for url in urls {
            #expect(url.contains("sealed=true"), "filter missing from a page: \(url)")
        }
        // Page two re-seeds from the cache rather than inheriting page one's cursor — see
        // `loadFirstPage`, which clears the continuation on purpose because page one's position
        // is nowhere near the end of a warm list. So page two carries `before=` and page three,
        // continuing from page two, carries `cursor=`.
        #expect(urls.filter { $0.contains("cursor=") }.count == 1)
        #expect(urls.filter { $0.contains("before=") }.count == 1)

        // Everything the screen holds is sealed, and nothing is there twice.
        let cached = try context.fetch(FetchDescriptor<Entry>())
        #expect(cached.count == 6, "six letters across three pages")
        #expect(cached.allSatisfy { $0.unlockAtAge != nil }, "an unsealed row reached a sealed list")
        #expect(Set(cached.map(\.id)).count == cached.count, "a row was paged twice")
        #expect(model.reachedEnd)
    }

    /// The property outlives the loop: a failed page is noted quietly and not retried on the
    /// spot. It used to also prove the drain did not spend ten pages on ten identical failures
    /// against a dead network; with no loop there is nothing to spend, so what is left is that
    /// one failed request stays one failed request and the cache stays on screen.
    @Test("a failed page is noted quietly and not retried on the spot")
    func doesNotRetryAFailure() async throws {
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { _ in (Data("{}".utf8), 500) }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.apply(.sealed)

        #expect(performer.count(for: "/entries") == 1, "one attempt, not a retry storm")
        #expect(model.notice != nil, "quietly noted, never a dialog over the archive")
    }

    @Test("an ordinary filter still makes exactly one request per load")
    func serverSideFiltersDoNotDrain() async throws {
        // The loop must be invisible to every filter the server can express: each row it returns
        // is a row the screen draws, so there is never a page with nothing in it.
        let context = try makeContext()
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/entries") { hit in
            (ordinaryPage(child: child, at: 1_700_000_000 - Double(hit) * 100_000, cursor: "c\(hit)"), 200)
        }

        let model = TimelineModel(childId: child, api: client(performer), context: context)
        await model.apply(.photo)

        #expect(performer.count(for: "/entries") == 1)
    }
}
