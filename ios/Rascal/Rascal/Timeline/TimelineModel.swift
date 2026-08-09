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

        let window: PageWindow
        if let continuation {
            window = .cursor(continuation)
        } else if let oldest = oldestCachedOccurredAt() {
            window = .before(oldest.addingTimeInterval(1))
        } else {
            // Nothing cached and nothing to continue from. There is no page after nothing.
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchPage(window)
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

    private func loadFirstPage() async {
        isLoadingFirstPage = true
        defer { isLoadingFirstPage = false }
        // Deliberately cleared. Page one's cursor describes where page one ended, which on a
        // warm cache is nowhere near where the list ends — the next `loadMore` must re-seed
        // from the cache rather than inherit it.
        continuation = nil
        reachedEnd = false
        pagedFilter = filter
        await fetchPage(.start)
    }

    private func fetchPage(_ window: PageWindow) async {
        do {
            let page = try await api.entries(
                childId: childId,
                type: filter.queryValue,
                before: { if case .before(let date) = window { date } else { nil } }(),
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

}
