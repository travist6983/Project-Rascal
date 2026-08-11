import Foundation
import SwiftData

/// Drives the timeline's paging and reconciles the server into the local cache.
///
/// It deliberately does **not** own the entries the screen draws. Those come from a `@Query`
/// over SwiftData, so the archive is on screen before any request goes out and stays there when
/// the phone has no signal. This object's whole job is to keep that cache fed: fetch a page,
/// fold it in, remember the cursor.
///
/// The consequence worth stating: an entry saved a moment ago and not yet pushed is in the
/// timeline, in the right place by `occurred_at`, exactly like one the server has had for a
/// year. Whether the server has heard about it is a fact about the network, not about the
/// archive.
@MainActor
@Observable
final class TimelineModel {

    /// 50 is the server's own default and its comfortable page. The cap is 200, and asking for
    /// it would trade a smoother scroll for a slower first paint on the screen that opens most.
    static let pageSize = 50

    private(set) var isLoadingFirstPage = false
    private(set) var isLoadingMore = false
    /// The server has no more pages for the current filter.
    private(set) var reachedEnd = false
    /// True once a page has come back. Until then, an empty screen means "nothing fetched yet",
    /// not "nothing in the archive" — and the two must not render the same.
    private(set) var hasLoaded = false
    /// A quiet note, never an error over the parent's archive.
    var notice: String?

    /// Changing this resets paging: a different filter is a different sequence of pages, and a
    /// cursor from one is meaningless in the other.
    var filter: TimelineFilter = .all

    private let childId: UUID
    private let api: APIClient
    private let context: ModelContext
    /// What the pages currently in hand were fetched under.
    private var pagedFilter: TimelineFilter = .all
    /// The server's keyset position from the last page of this run, or nil when the next request
    /// should re-seed from the bottom of the cache. See `loadMoreIfNeeded`.
    private var continuation: String?

    init(childId: UUID, api: APIClient, context: ModelContext) {
        self.childId = childId
        self.api = api
        self.context = context
    }

    // MARK: Loading

    /// First paint. A no-op once a page has landed, so returning to the tab does not refetch.
    func start() async {
        guard !hasLoaded, !isLoadingFirstPage else { return }
        await loadFirstPage()
    }

    /// Pull to refresh. Re-reads page one and forgets any thumbnail that failed — the gesture
    /// means "try again", and it should mean that for pictures too.
    func refresh(thumbnails: ThumbnailStore? = nil) async {
        thumbnails?.retryFailures()
        await loadFirstPage()
    }

    /// The filter row. Resets paging, then fetches under the new type.
    func apply(_ newFilter: TimelineFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await loadFirstPage()
    }

    /// Called when the last card on screen appears. Guarded on every side, because a scroll can
    /// ask several times before the first answer arrives.
    ///
    /// **Seeded from the cache, then carried by the server's cursor.** Both halves are load
    /// bearing, and each one is there because the other alone was wrong:
    ///
    /// - *The cursor alone cannot start.* Reopen the app with fifteen pages cached and a
    ///   remembered page-one cursor asks for page two — entirely rows already held. No new card
    ///   appears, so nothing triggers again, and the archive stops at the bottom of the cache
    ///   with years still unfetched. A device found that one.
    /// - *`before` alone cannot continue.* It is exclusive and compares only `occurred_at`, so a
    ///   page that comes back entirely inside the overlap window returns rows the cache already
    ///   has, the floor does not move, and paging has no way to get past them. Fifty entries
    ///   sharing one second is not hypothetical — it is what a bulk import of photos with no
    ///   EXIF date looks like.
    ///
    /// So the first request of a run asks for everything older than the oldest row on screen,
    /// and every request after it follows `next_cursor`, which is a true keyset position on
    /// `(occurred_at, id)` and therefore advances even when every row on a page is a duplicate.
    /// The second of overlap on the seed is deliberate: it re-delivers a row or two the cache
    /// already holds, which costs nothing because upserts are by id, and it cannot skip the twin
    /// of a row sitting exactly on the boundary. **Overlap rather than skip**, in a permanent
    /// archive, every time.
    func loadMoreIfNeeded() async {
        guard hasLoaded, !reachedEnd, !isLoadingMore, !isLoadingFirstPage else { return }
        // Nothing cached and nothing to continue from. There is no page after nothing.
        guard let window = nextWindow() else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        await drain(from: window)
    }

    /// Where the next page starts.
    private enum PageWindow {
        /// The very first request of a run: no window at all.
        case start
        /// Seeded from the bottom of the cache.
        case before(Date)
        /// The server's own keyset position, from the previous page.
        case cursor(String)
    }

    private func nextWindow() -> PageWindow? {
        if let continuation { return .cursor(continuation) }
        if let oldest = oldestCachedOccurredAt() { return .before(oldest.addingTimeInterval(1)) }
        return nil
    }

    private func loadFirstPage() async {
        isLoadingFirstPage = true
        defer { isLoadingFirstPage = false }
        // Deliberately cleared. Page one's cursor describes where page one ended, which on a
        // warm cache is nowhere near where the list ends — the next `loadMore` must re-seed
        // from the cache rather than inherit it.
        continuation = nil
        reachedEnd = false
        pagedFilter = filter
        await drain(from: .start)
    }

    /// Fetch a page. **One request, for every filter.**
    ///
    /// This used to be a loop with a ten-page budget, and the budget existed for exactly one
    /// chip: `sealed` had no server parameter, so the client asked for the whole archive and
    /// narrowed it locally — and a page of fifty ordinary entries added no visible card, while
    /// **a page that adds no card also adds nothing to trigger the next one**, because paging
    /// hangs off the last card appearing. The loop was what stopped the filter dying on any
    /// stretch of archive without a letter in it, at the cost of the screen only ever being able
    /// to claim "none in the last five hundred" rather than "none".
    ///
    /// `?sealed=true` removed the reason. Every row the server returns is now a row the screen
    /// will draw, under every chip, so one page in is one page drawn.
    ///
    /// **Kept as a function rather than inlined**, because it is the single paging entry point
    /// that `loadFirstPage` and `loadMore` both go through — the loop was the workaround, not
    /// this seam.
    private func drain(from first: PageWindow) async {
        await fetchPage(first)
    }

    /// **Returned nothing to the caller since the drain loop went.** It used to answer
    /// `matched` / `empty` / `failed`, and the only reader was the loop deciding whether to
    /// spend another page looking for a sealed letter. Every filter is a server filter now, so
    /// every row that arrives is a row the screen draws and there is nothing left to ask.
    private func fetchPage(_ window: PageWindow) async {
        do {
            let page = try await api.entries(
                childId: childId,
                type: filter.serverType,
                before: { if case .before(let date) = window { date } else { nil } }(),
                // The Sealed chip, on the wire instead of in a local narrowing pass.
                sealed: filter.serverSealed,
                limit: Self.pageSize,
                cursor: { if case .cursor(let value) = window { value } else { nil } }()
            )
            // A filter changed while this was in flight. Its rows are still worth caching —
            // they are real entries — but its position belongs to a list nobody is reading.
            EntryCache.upsert(page.entries, into: context)
            guard pagedFilter == filter else { return }

            switch window {
            case .start:
                // See `loadFirstPage`. Page one's position is not a continuation.
                continuation = nil
            case .before, .cursor:
                continuation = page.nextCursor
            }
            // Null `next_cursor` is the server saying this was the last page, whichever way it
            // was asked for.
            reachedEnd = page.nextCursor == nil
            hasLoaded = true
            notice = nil
        } catch let error as APIError {
            // The cache is already on screen. A failed refetch must not blank it, and offline
            // is not a failure worth a dialog.
            notice = error.userMessage
            hasLoaded = true
        } catch {
            notice = error.localizedDescription
            hasLoaded = true
        }
    }

    /// The oldest row **the server has given us**, under the filter the server is applying.
    ///
    /// Keyed on `serverType`, not on the filter: under `sealed` the server is paging the whole
    /// archive, so the seed has to be the oldest row of any kind. Seeding from the oldest sealed
    /// letter would ask for everything older than it and skip every ordinary entry in between —
    /// which is fine for the sealed list itself and quietly strands the cache for every other.
    ///
    /// Filtered the same way the screen's `@Query` is, with one addition that is easy to miss
    /// and expensive to get wrong: `existsOnServer`. A row written on this phone and not yet
    /// pushed is on screen, but it is **not a position in the server's ordering** — the server
    /// has never heard of it. Someone scans a photo from 1990 and files it on the day it was
    /// taken; it becomes the bottom of the list, the seed asks for everything older than 1990,
    /// the answer is nothing, and every page between there and the last one fetched is stranded
    /// until the next refresh. Backdating is a first-class flow here, so this is a thing that
    /// happens, not an edge case.
    private func oldestCachedOccurredAt() -> Date? {
        let child = childId
        var descriptor: FetchDescriptor<Entry>
        if let wanted = filter.serverType {
            descriptor = FetchDescriptor<Entry>(
                predicate: #Predicate<Entry> { entry in
                    entry.childId == child && entry.deletedAt == nil
                        && entry.existsOnServer && entry.entryType == wanted
                },
                sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
            )
        } else if filter.serverSealed != nil {
            // **The seed has to match the filter, and for `sealed` it did not used to.**
            //
            // While the Sealed chip narrowed locally, the request was unfiltered and the right
            // seed was the oldest cached row of *any* kind — seeding from the oldest cached
            // letter would have stranded every ordinary entry between it and the present.
            //
            // `?sealed=true` inverts that. The request now returns letters and only letters, so
            // seeding from the oldest cached row of any kind asks for letters older than an
            // entry that may be years older than the oldest letter — and every letter in between
            // is skipped, silently, on a list that looks complete. Browse All to the bottom of
            // 2019, switch to Sealed, scroll: page two starts before 2019 and the letters from
            // 2020 onward never arrive.
            descriptor = FetchDescriptor<Entry>(
                predicate: #Predicate<Entry> { entry in
                    entry.childId == child && entry.deletedAt == nil
                        && entry.existsOnServer && entry.unlockAtAge != nil
                },
                sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<Entry>(
                predicate: #Predicate<Entry> { entry in
                    entry.childId == child && entry.deletedAt == nil && entry.existsOnServer
                },
                sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
            )
        }
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.occurredAt
    }

}
