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
    private var cursor: String?
    /// What the pages currently in hand were fetched under.
    private var pagedFilter: TimelineFilter = .all

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

    /// Called when the last card appears. Guarded on every side, because a scroll can ask
    /// several times before the first answer arrives.
    func loadMoreIfNeeded() async {
        guard hasLoaded, !reachedEnd, !isLoadingMore, !isLoadingFirstPage, cursor != nil else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchPage(cursor: cursor)
    }

    private func loadFirstPage() async {
        isLoadingFirstPage = true
        defer { isLoadingFirstPage = false }
        cursor = nil
        reachedEnd = false
        pagedFilter = filter
        await fetchPage(cursor: nil)
    }

    private func fetchPage(cursor requested: String?) async {
        do {
            let page = try await api.entries(
                childId: childId,
                type: filter.queryValue,
                limit: Self.pageSize,
                cursor: requested
            )
            // A filter changed while this was in flight. Its rows are still worth caching —
            // they are real entries — but its cursor belongs to a sequence nobody is reading.
            EntryCache.upsert(page.entries, into: context)
            guard pagedFilter == filter else { return }

            cursor = page.nextCursor
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
