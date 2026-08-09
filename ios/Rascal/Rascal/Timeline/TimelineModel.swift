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
    /// The `before` this last asked for, so a page that returns only rows already held cannot
    /// become a loop.
    private var lastBefore: Date?

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
    /// **Paging is seeded from the cache, not from a token.** The endpoint hands back an opaque
    /// `next_cursor`, and for a stateless pager that is exactly the right tool — but this client
    /// is offline-first, and its answer to "where am I" is the archive already on screen rather
    /// than a position remembered from one session. A device found the difference: reopen the
    /// app with fifteen pages cached and the page-one cursor asks for page two, which is
    /// entirely rows already held. No new card appears, so nothing triggers again, and the
    /// timeline stops at the bottom of the cache with years still unfetched.
    ///
    /// So it asks for what it does not have: everything older than the oldest row on screen.
    /// The overlap is deliberate — `before` is exclusive and two entries can share an instant,
    /// so a boundary drawn exactly at the oldest row can skip its twin. A second of overlap
    /// re-delivers rows the cache already has, which costs nothing because upserts are by id.
    /// That is the same trade `GET /sync` makes when it hands back a cursor thirty seconds
    /// behind: **overlap rather than skip**, in a permanent archive, every time.
    func loadMoreIfNeeded() async {
        guard hasLoaded, !reachedEnd, !isLoadingMore, !isLoadingFirstPage else { return }
        guard let oldest = oldestCachedOccurredAt() else { return }

        let before = oldest.addingTimeInterval(1)
        guard before != lastBefore else {
            // The last request did not move the floor, so every row it returned was one the
            // cache already had. There is nothing older to fetch.
            reachedEnd = true
            return
        }
        lastBefore = before

        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchPage(before: before)
    }

    private func loadFirstPage() async {
        isLoadingFirstPage = true
        defer { isLoadingFirstPage = false }
        lastBefore = nil
        reachedEnd = false
        pagedFilter = filter
        await fetchPage(before: nil)
    }

    private func fetchPage(before: Date?) async {
        do {
            let page = try await api.entries(
                childId: childId,
                type: filter.queryValue,
                before: before,
                limit: Self.pageSize
            )
            // A filter changed while this was in flight. Its rows are still worth caching —
            // they are real entries — but its position belongs to a list nobody is reading.
            EntryCache.upsert(page.entries, into: context)
            guard pagedFilter == filter else { return }

            // `next_cursor` is not used to page, but it is still the server's own answer to
            // "is there more after this": it is set whenever another page exists, and null on
            // the last one. Read as a signal rather than as a position.
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

    /// The oldest row the list is currently showing, under the active filter.
    ///
    /// Filtered the same way the screen's `@Query` is, so "the bottom of the list" means the
    /// same thing to the pager as it does to the parent looking at it.
    private func oldestCachedOccurredAt() -> Date? {
        let child = childId
        var descriptor: FetchDescriptor<Entry>
        if let wanted = filter.queryValue {
            descriptor = FetchDescriptor<Entry>(
                predicate: #Predicate<Entry> { entry in
                    entry.childId == child && entry.deletedAt == nil && entry.entryType == wanted
                },
                sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<Entry>(
                predicate: #Predicate<Entry> { entry in
                    entry.childId == child && entry.deletedAt == nil
                },
                sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
            )
        }
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.occurredAt
    }

    // MARK: Deleting

    /// Soft delete, local first.
    ///
    /// The row is marked and gone from the list before the request goes out; `EntrySync` pushes
    /// the `DELETE` and retries it on the next foreground if this attempt does not land. Nothing
    /// is ever removed from SwiftData — a deletion the client cannot describe is a deletion that
    /// cannot sync.
    func delete(_ entry: Entry) async {
        await EntryCache.delete(entry, api: api, in: context)
    }
}
