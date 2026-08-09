import Foundation
import SwiftData

/// `GET /entries?q=` — the smallest surface that makes transcription observable.
///
/// **Deliberately minimal, and it is worth saying why it exists at all.** Transcription writes
/// words into a database this app had no way to query. Without this the feature produces text
/// nobody can see, and there is no way to check in the morning whether it worked. Everything a
/// search screen usually grows — filters combined with search, history, saved searches, in-text
/// highlighting, offline search over the cache — is out of scope and stayed out.
///
/// ## Why this is not `TimelineModel`
///
/// The two modes page differently and the server enforces it: the timeline is keyset-paginated on
/// `(occurred_at, id)`, search on `(rank, occurred_at, id)`, and handing a cursor from one to the
/// other answers **422** rather than a quietly wrong page. Sharing a model would mean sharing a
/// `continuation`, which is precisely the thing that must not be shared.
///
/// It also does not seed from the cache the way `TimelineModel` does. There is no local ordering
/// by relevance to seed from — rank is the server's answer and only the server has it — so search
/// starts at page one every time and follows `next_cursor` from there.
@MainActor
@Observable
final class TimelineSearchModel {

    /// Long enough that typing "brachiosaurus" is one request rather than fourteen, short enough
    /// that it still feels like the list is keeping up. The cancellation below is what makes the
    /// number a comfort setting rather than a correctness one.
    /// `nonisolated` because it is the default argument of this type's own initialiser, which is
    /// evaluated in a nonisolated context — the same reason `MediaCoordinator` defaults its
    /// uploader inside the body rather than in the signature.
    nonisolated static let debounce: Duration = .milliseconds(300)

    /// The server's own default page. Same as the timeline's, for the same reason.
    static let pageSize = 50

    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    /// True once a query has come back. Until then an empty list means "nothing asked yet", not
    /// "nothing found" — and the two must not render the same.
    private(set) var hasSearched = false
    /// A quiet note, never an error over the parent's archive.
    private(set) var notice: String?

    /// Matching entry ids **in the server's order**, which is by relevance and then by date.
    private(set) var resultIds: [UUID] = []
    /// The query the results on screen belong to, so a card can say what it matched.
    private(set) var matchedQuery: String?

    private let childId: UUID
    private let api: APIClient
    private let context: ModelContext
    /// How long a keystroke waits. Injectable **only** so the suite can drive it to zero: a test
    /// that sleeps for a real debounce is a test whose result depends on how loaded the machine
    /// is, and this suite runs in parallel with forty others. Same narrow-seam precedent as
    /// `SyncEngine.Hooks` and `APIClient.refreshCount`; nothing that ships passes it.
    private let debounce: Duration
    /// The server's keyset position within *this* search. Never crosses into the timeline's.
    private var continuation: String?
    /// The in-flight run. Cancelling it is what both debounces and abandons a stale request —
    /// one mechanism, because they are the same act at two different moments.
    private var inFlight: Task<Void, Never>?

    init(
        childId: UUID,
        api: APIClient,
        context: ModelContext,
        debounce: Duration = TimelineSearchModel.debounce
    ) {
        self.childId = childId
        self.api = api
        self.context = context
        self.debounce = debounce
    }

    var isEmpty: Bool { resultIds.isEmpty }

    /// Await whatever `search(_:)` started, so a test can assert on a settled model rather than
    /// on a stopwatch. Returns immediately when nothing is running.
    func waitForInFlight() async {
        await inFlight?.value
    }

    /// The run currently in flight, so a test can hold onto one that is about to be cancelled and
    /// watch it finish.
    ///
    /// A narrow, deliberately ugly seam — same precedent as `SyncEngine.Hooks` and
    /// `APIClient.refreshCount`, and nil-safe in every shipped path because nothing that ships
    /// reads it. It exists because the rule it proves is otherwise unobservable from outside: an
    /// abandoned request must write **nothing**, and "nothing" cannot be asserted until the thing
    /// that would have written it has definitely finished.
    var currentRun: Task<Void, Never>? { inFlight }

    // MARK: Searching

    /// A keystroke.
    ///
    /// **Debounce and cancellation are the same `Task`.** The previous run is cancelled before
    /// anything else happens, so a run still inside its sleep never issues a request at all, and
    /// one already awaiting the network is abandoned before it can write results belonging to a
    /// query the parent has since typed past. Ordering by arrival would otherwise let a slow first
    /// request land on top of a fast second one, which is how a search box shows answers to a
    /// question nobody asked.
    func search(_ raw: String) {
        inFlight?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            inFlight = nil
            clear()
            return
        }

        inFlight = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.run(query)
        }
    }

    /// Called when the last result on screen appears, exactly as the timeline does it.
    func loadMoreIfNeeded() async {
        guard hasSearched, !reachedEnd, !isSearching, !isLoadingMore,
              let query = matchedQuery, let cursor = continuation
        else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetch(query, cursor: cursor)
    }

    /// Leave search. Everything about the previous query goes with it, including its cursor —
    /// a position in one result set means nothing in the next.
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        resultIds = []
        matchedQuery = nil
        continuation = nil
        reachedEnd = false
        hasSearched = false
        isSearching = false
        notice = nil
    }

    private func run(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        // A new query is a new sequence of pages. Carrying the old cursor across would ask the
        // server to continue a ranking it is no longer computing.
        continuation = nil
        reachedEnd = false
        resultIds = []
        await fetch(query, cursor: nil)
    }

    private func fetch(_ query: String, cursor: String?) async {
        do {
            let page = try await api.entries(
                childId: childId,
                query: query,
                limit: Self.pageSize,
                cursor: cursor
            )
            // Cached like every other page, so the cards render from SwiftData and an entry found
            // by search is an entry the archive holds rather than a second kind of row.
            EntryCache.upsert(page.entries, into: context)

            guard !Task.isCancelled else { return }
            // Appended in wire order and de-duplicated: the server's ranking *is* the order, and
            // re-sorting it here would throw away the only thing search knows that the cache
            // does not.
            let known = Set(resultIds)
            resultIds.append(contentsOf: page.entries.map(\.id).filter { !known.contains($0) })
            matchedQuery = query
            continuation = page.nextCursor
            // Null `next_cursor` is the server saying that was the last page.
            reachedEnd = page.nextCursor == nil
            hasSearched = true
            notice = nil
        } catch {
            // **Checked on the failure path too, and this is not symmetry for its own sake.** A
            // cancelled request surfaces as a thrown error, so without this the abandoned query
            // writes a notice and marks the list finished — over results belonging to the query
            // the parent is actually looking at, and *after* them, because the cancellation lands
            // later than the request that replaced it.
            guard !Task.isCancelled else { return }
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
            hasSearched = true
            // Not retried and not advanced. The cursor stays where the last good page left it.
            reachedEnd = true
        }
    }
}
