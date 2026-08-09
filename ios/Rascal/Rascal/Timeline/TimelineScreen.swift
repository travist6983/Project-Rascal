import SwiftData
import SwiftUI

/// The archive, scrollable.
///
/// A **scannable archive, not a story feed** — full-bleed edge-to-edge photo cards are on the
/// rejected list in `docs/design-system.md` and are not coming back. Cards on cream, one row per
/// entry, grouped by the day it happened.
///
/// It renders from SwiftData first and reconciles with the server second, which is what makes it
/// open instantly on a plane and what puts an entry written thirty seconds ago in its right place
/// by `occurred_at` rather than at the bottom of a list waiting for a round trip.
struct TimelineScreen: View {
    let childId: UUID
    let api: APIClient
    /// Runs the push-then-pull sweep. Pull to refresh means "show me what is actually there",
    /// and page one of `GET /entries` is only half of that — a deletion made elsewhere never
    /// appears in a page, only in `/sync`.
    var onSync: () async -> Void = {}
    let openComposer: (ComposerRequest) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.thumbnails) private var thumbnails
    @State private var model: TimelineModel?
    @State private var search: TimelineSearchModel?
    @State private var path: [UUID] = []
    /// What is in the field. Held here rather than in the model because it changes on every
    /// keystroke and the model should only hear about it through `search(_:)`, which debounces.
    @State private var searchText = ""
    @State private var isSearchOpen = false

    var body: some View {
        NavigationStack(path: $path) {
            TimelineList(
                childId: childId,
                filter: model?.filter ?? .all,
                isLoading: model?.isLoadingFirstPage ?? true,
                hasLoaded: model?.hasLoaded ?? false,
                isLoadingMore: model?.isLoadingMore ?? false,
                reachedEnd: model?.reachedEnd ?? false,
                notice: model?.notice,
                search: searchState,
                searchText: $searchText,
                onSelectFilter: { filter in Task { await model?.apply(filter) } },
                onOpen: { path.append($0) },
                onReachEnd: {
                    // One trigger, two lists. Whichever one is on screen is the one that pages.
                    if isSearchOpen {
                        await search?.loadMoreIfNeeded()
                    } else {
                        await model?.loadMoreIfNeeded()
                    }
                },
                onRefresh: {
                    await model?.refresh(thumbnails: thumbnails)
                    await onSync()
                },
                onClearFilter: { Task { await model?.apply(.all) } },
                onCompose: { openComposer(ComposerRequest(childId: childId, assignment: nil, mode: .text)) },
                onOpenSearch: { isSearchOpen = true },
                onCloseSearch: {
                    isSearchOpen = false
                    searchText = ""
                    search?.clear()
                },
                onQueryChange: { search?.search($0) }
            )
            // Rebuilt when the filter changes — `@Query`'s predicate is fixed at init — and when
            // search opens or closes, because a search reads the whole archive regardless of which
            // filter chip is selected underneath it.
            .id(SearchIdentity(filter: model?.filter ?? .all, searching: isSearchOpen))
            .background(Color.canvas)
            // The list is the root of its own stack and wears no navigation bar: v3 gives it a
            // sticky header of its own, carrying the screen's name, its count, and the filters.
            // The detail pushed on top of it gets the standard bar, with a back chevron.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                EntryDetailScreen(
                    entryId: id,
                    childId: childId,
                    api: api,
                    openComposer: openComposer,
                    onDeleted: { path.removeAll { $0 == id } }
                )
            }
        }
        .task {
            if model == nil {
                model = TimelineModel(childId: childId, api: api, context: context)
            }
            if search == nil {
                search = TimelineSearchModel(childId: childId, api: api, context: context)
            }
            await model?.start()
        }
    }

    /// What the list needs to draw results, flattened out of the model.
    ///
    /// Nil whenever search is closed, which is what makes "the timeline" and "results" one screen
    /// rather than two: the same list, the same cards, the same day headers.
    private var searchState: TimelineSearchState? {
        guard isSearchOpen, let search else { return nil }
        return TimelineSearchState(
            query: search.matchedQuery,
            resultIds: search.resultIds,
            isSearching: search.isSearching,
            isLoadingMore: search.isLoadingMore,
            hasSearched: search.hasSearched,
            notice: search.notice
        )
    }
}

/// What the list is currently showing, for `@Query`'s benefit.
///
/// `@Query` fixes its predicate at initialisation, so the list has to be a new instance whenever
/// either half of this changes. A struct rather than two `.id` modifiers because SwiftUI takes one
/// identity, and two calls would mean the second silently won.
private struct SearchIdentity: Hashable {
    let filter: TimelineFilter
    let searching: Bool
}

/// A snapshot of the search, for the list to render.
struct TimelineSearchState: Equatable {
    /// The query the results belong to, which is not necessarily what is in the field — the field
    /// is ahead of the results by up to one debounce, and the cards must describe what they are.
    let query: String?
    /// In the server's order: relevance, then newest first.
    let resultIds: [UUID]
    let isSearching: Bool
    let isLoadingMore: Bool
    let hasSearched: Bool
    let notice: String?
}

/// The list itself, separated so its `@Query` can be built with the active filter.
///
/// `@Query`'s predicate is fixed at initialisation, so filtering means a new instance — hence the
/// `.id(filter)` on the caller. That is also why this takes plain values rather than the model:
/// it is rebuilt whenever the filter changes, and it should carry nothing that would be
/// expensive to recreate.
private struct TimelineList: View {
    let filter: TimelineFilter
    let isLoading: Bool
    let hasLoaded: Bool
    let isLoadingMore: Bool
    let reachedEnd: Bool
    let notice: String?
    let search: TimelineSearchState?
    @Binding var searchText: String
    let onSelectFilter: (TimelineFilter) -> Void
    let onOpen: (UUID) -> Void
    let onReachEnd: () async -> Void
    let onRefresh: () async -> Void
    let onClearFilter: () -> Void
    let onCompose: () -> Void
    let onOpenSearch: () -> Void
    let onCloseSearch: () -> Void
    let onQueryChange: (String) -> Void

    @Query private var entries: [Entry]
    @Query private var media: [Media]
    @Query private var assignments: [Assignment]
    @FocusState private var fieldFocused: Bool

    init(
        childId: UUID,
        filter: TimelineFilter,
        isLoading: Bool,
        hasLoaded: Bool,
        isLoadingMore: Bool,
        reachedEnd: Bool,
        notice: String?,
        search: TimelineSearchState?,
        searchText: Binding<String>,
        onSelectFilter: @escaping (TimelineFilter) -> Void,
        onOpen: @escaping (UUID) -> Void,
        onReachEnd: @escaping () async -> Void,
        onRefresh: @escaping () async -> Void,
        onClearFilter: @escaping () -> Void,
        onCompose: @escaping () -> Void,
        onOpenSearch: @escaping () -> Void,
        onCloseSearch: @escaping () -> Void,
        onQueryChange: @escaping (String) -> Void
    ) {
        self.filter = filter
        self.isLoading = isLoading
        self.hasLoaded = hasLoaded
        self.isLoadingMore = isLoadingMore
        self.reachedEnd = reachedEnd
        self.notice = notice
        self.search = search
        self._searchText = searchText
        self.onSelectFilter = onSelectFilter
        self.onOpen = onOpen
        self.onReachEnd = onReachEnd
        self.onRefresh = onRefresh
        self.onClearFilter = onClearFilter
        self.onCompose = onCompose
        self.onOpenSearch = onOpenSearch
        self.onCloseSearch = onCloseSearch
        self.onQueryChange = onQueryChange

        // Sorted by `occurred_at`, descending. Not `created_at` — a photo from 2019 added
        // tonight belongs in 2019, and sorting by when the row was made is the exact bug the
        // two timestamps exist to prevent.
        let sort = [SortDescriptor(\Entry.occurredAt, order: .reverse)]
        // **Search reads the whole archive.** Combining a filter chip with a query is explicitly
        // out of scope, and narrowing the query behind it would silently drop results the server
        // ranked and returned.
        if search != nil {
            _entries = Query(
                filter: #Predicate<Entry> { entry in
                    entry.childId == childId && entry.deletedAt == nil
                },
                sort: sort
            )
        } else if filter == .sealed {
            // Sealed is `unlock_at_age`, not an `entry_type` — there is no `?type=` for it, so
            // the server pages the whole archive and the narrowing happens here. See
            // `TimelineModel.drain` for how paging survives a page with nothing in it.
            _entries = Query(
                filter: #Predicate<Entry> { entry in
                    entry.childId == childId && entry.deletedAt == nil && entry.unlockAtAge != nil
                },
                sort: sort
            )
        } else if let wanted = filter.serverType {
            _entries = Query(
                filter: #Predicate<Entry> { entry in
                    entry.childId == childId && entry.deletedAt == nil && entry.entryType == wanted
                },
                sort: sort
            )
        } else {
            _entries = Query(
                filter: #Predicate<Entry> { entry in
                    entry.childId == childId && entry.deletedAt == nil
                },
                sort: sort
            )
        }
        // One query for every live media row, grouped once below, rather than a fetch per card.
        // The list must never fan out into a request or a query per entry.
        _media = Query(
            filter: #Predicate<Media> { $0.deletedAt == nil },
            sort: [SortDescriptor(\Media.createdAt, order: .forward)]
        )
        // The prompts, for the quote each card is built around. Assignments carry the same
        // sentence `GET /entries/{id}` returns, `/sync` keeps them current, and nothing evicts
        // them — so the quote is there on a cold launch with no signal.
        _assignments = Query(filter: #Predicate<Assignment> { $0.childId == childId })
    }

    var body: some View {
        let groups = TimelineGrouping.days(cards, occurredAt: \.occurredAt)

        Group {
            if groups.isEmpty {
                emptyState
            } else {
                list(groups)
            }
        }
        .background(Color.canvas)
        // Reserves its own height and lets the archive scroll underneath it, which is what the
        // translucency below is for.
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    // MARK: Header

    /// The screen's name, what it holds, and the filters — one strip, floating over the archive.
    ///
    /// Searching replaces the title row with the field and hides the filters, because a filter
    /// chip that no longer narrows anything is a control that lies. It is the same strip either
    /// way rather than a second screen: search is a way of looking at the timeline, not a place.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search != nil {
                searchField
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.bottom, 10)
            } else {
                titleRow
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.bottom, 10)
                TimelineFilterRow(selection: filter, onSelect: onSelectFilter)
            }
        }
        .padding(.top, 10)
        .background {
            // Cream at 94% over a blur, so a card scrolling behind the strip is softened rather
            // than hidden. A solid bar would read as a second screen edge.
            Color.canvas.opacity(0.94).background(.ultraThinMaterial)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Timeline")
                .typeRole(.screenTitle)
                .foregroundStyle(Color.ink)
            Spacer(minLength: 0)
            if let countLabel {
                Text(countLabel)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
            Button(action: onOpenSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.inkMuted)
                    // A 44pt target on a 16pt glyph. The strip is the one place on this screen
                    // where a thumb reaching from the bottom arrives at an angle.
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel("Search the archive")
        }
    }

    /// One field and one way out. No scope bar, no recent searches, no suggestions.
    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.inkFaint)
                TextField("Search the archive", text: $searchText)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($fieldFocused)
                    .onChange(of: searchText) { _, value in onQueryChange(value) }
                if search?.isSearching == true {
                    ProgressView().tint(.inkFaint).controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))

            Button("Cancel", action: onCloseSearch)
                .typeRole(.body)
                .foregroundStyle(Color.terracotta)
        }
        // Opening the affordance should put a cursor in the field. Anything else means the
        // magnifier costs two taps to do one thing.
        .onAppear { fieldFocused = true }
    }

    /// How much is here — and it never claims to know the size of the archive.
    ///
    /// `entries` is what has been paged in, not what the server holds, so until the last page
    /// has landed this says **"so far"** and means it. Printing a total the client has not
    /// counted would be the timeline inventing a fact about the archive.
    private var countLabel: String? {
        guard hasLoaded, !entries.isEmpty else { return nil }
        let noun = entries.count == 1 ? "entry" : "entries"
        return reachedEnd ? "\(entries.count) \(noun)" : "\(entries.count) so far"
    }

    // MARK: Rows

    /// Flattened once per render rather than per card, so a five-hundred row list does one pass
    /// over its media instead of five hundred lookups through SwiftData.
    ///
    /// Under search this draws the same cards from the same cache, narrowed to what the server
    /// returned and **in the order the server returned it**. Rank is the server's answer and
    /// nothing on device can recompute it, so the ordering is carried rather than derived.
    private var cards: [EntryCardModel] {
        let byEntry = Dictionary(grouping: media, by: \.entryId)
        // Built once for the whole screen. A lookup per card would be a linear scan of every
        // assignment ever synced, five hundred times over.
        let promptByAssignment = Dictionary(
            assignments.map { ($0.id, $0.body) },
            uniquingKeysWith: { first, _ in first }
        )

        func card(_ entry: Entry) -> EntryCardModel {
            EntryCardModel(
                entry: entry,
                media: byEntry[entry.id] ?? [],
                assignedPrompt: entry.assignmentId.flatMap { promptByAssignment[$0] },
                searchQuery: search?.query
            )
        }

        guard let search else { return entries.map(card) }
        // One pass to index, then one to order. The alternative — `first(where:)` per result id —
        // is quadratic over an archive the cache may hold thousands of.
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return search.resultIds.compactMap { byId[$0] }.map(card)
    }

    private func list(_ groups: [TimelineGrouping.Day<EntryCardModel>]) -> some View {
        // The paging trigger hangs off the last card, not off a footer row.
        //
        // A footer's `.task` fires once, when the row is first created — which on this screen is
        // during the first render, *before* the first page has landed. Every guard in
        // `loadMoreIfNeeded` was correctly false at that moment, the task never ran again
        // because the footer's identity never changed, and paging stopped dead at page one. It
        // took a device to see it: every unit test drives the model directly and none of them
        // has a view lifecycle to get wrong.
        //
        // The last card is right for the same reason the footer was wrong. Its identity changes
        // every time a page lands, so a new one appears — but only when it is actually scrolled
        // to, which is exactly when another page is wanted.
        let lastCardId = groups.last?.items.last?.id

        return List {
            if let notice = activeNotice { noticeRow(notice) }

            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { card in
                        // A button rather than a `NavigationLink`: inside a `List`, a link
                        // draws a disclosure chevron on every row, and a chevron on a card is
                        // furniture the design does not have.
                        Button { onOpen(card.id) } label: {
                            EntryCard(model: card)
                        }
                        .buttonStyle(TapScaleButtonStyle())
                        .listRowInsets(EdgeInsets(
                            top: Layout.cardSpacing / 2, leading: Layout.screenMargin,
                            bottom: Layout.cardSpacing / 2, trailing: Layout.screenMargin
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.canvas)
                        .onAppear {
                            guard card.id == lastCardId else { return }
                            Task { await onReachEnd() }
                        }
                    }
                } header: {
                    DayHeader(
                        date: group.start,
                        yearDivider: group.yearDivider,
                        // Every entry under one date belongs to one child on one day, so the
                        // age is a property of the group. In v3 it is stated once here instead
                        // of repeating on every card below it.
                        ageMonths: group.items.first?.ageMonths
                    )
                }
            }

            footer
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .environment(\.defaultMinListHeaderHeight, 0)
        .refreshable { await onRefresh() }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.inkMuted)
            Text(text).typeRole(.metadata).foregroundStyle(Color.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
        .listRowInsets(EdgeInsets(top: 8, leading: Layout.screenMargin, bottom: 4, trailing: Layout.screenMargin))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.canvas)
    }

    /// The spinner under the last card while another page is in flight, and the closing line
    /// once there is no page after it. Neither carries a paging trigger — see `list(_:)` for
    /// where paging is actually driven from, and why.
    private var footer: some View {
        VStack(spacing: 0) {
            if search?.isLoadingMore ?? isLoadingMore {
                ProgressView().tint(.terracotta).frame(height: 44)
            } else if search == nil, reachedEnd {
                // No closing line under search. "Keep scrolling and it only gets younger" is a
                // sentence about an archive, and a page of results is not one.
                Text(closingLine)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Layout.screenMargin + 2)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.canvas)
    }

    /// The line at the bottom of the archive.
    ///
    /// It says what scrolling further would do and nothing else — **no count of days, no
    /// streak, no note about how long it has been.** The bottom of a permanent archive is the
    /// last place to start keeping score.
    private var closingLine: String {
        filter == .all
            ? "Keep scrolling and it only gets younger."
            : "That's every one of these in the archive."
    }

    // MARK: Empty

    /// The notice on screen belongs to whichever list is on screen.
    private var activeNotice: String? {
        search != nil ? search?.notice : notice
    }

    @ViewBuilder
    private var emptyState: some View {
        if let search {
            searchEmpty(search)
        } else if isLoading && !hasLoaded {
            // Nothing fetched yet is not the same as nothing in the archive, and they must not
            // render the same.
            ProgressView().tint(.terracotta)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filter != .all {
            filteredEmpty
        } else {
            archiveEmpty
        }
    }

    /// The first-run state. A soft wash and one clear thing to do — not a shrug, and not an
    /// instruction that implies the parent is behind.
    private var archiveEmpty: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.terracotta)
            Text("The archive starts here")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text("Everything you save lands on the day it happened, whether that was tonight or six years ago.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Button("Write the first one", action: onCompose)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Gradients.wash, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
        .padding(Layout.screenMargin)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// Nothing found, or nothing asked yet.
    ///
    /// **One line, no illustration, no suggestions.** A search that comes back empty is not an
    /// error and it is not a moment — the parent typed a word their archive does not contain, and
    /// the only useful thing to say is so.
    @ViewBuilder
    private func searchEmpty(_ state: TimelineSearchState) -> some View {
        if !state.hasSearched {
            // Before the first result lands. Deliberately blank rather than a spinner: the field
            // already shows one, and a second on the canvas would make typing feel like waiting.
            Color.clear
        } else {
            Text(state.query.map { "Nothing in the archive matches “\($0)”." } ?? "")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Layout.screenMargin)
                .padding(.top, 40)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// A filter with nothing behind it. Quieter than the first-run state on purpose: nothing is
    /// missing, the archive simply has none of this kind yet.
    private var filteredEmpty: some View {
        VStack(spacing: 10) {
            Text("Nothing here yet")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text("No \(filter.emptyNoun) so far.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
            Button("Show everything", action: onClearFilter)
                .typeRole(.metadata)
                .foregroundStyle(Color.terracotta)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, Layout.screenMargin)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// **9** August 2026 · SUN, with the age he was that day on the right, and a year rule above it
/// where the calendar turns over.
struct DayHeader: View {
    let date: Date
    let yearDivider: Int?
    var ageMonths: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let yearDivider { yearRule(yearDivider) }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The day number carries the weight; the month is the lighter half of the pair,
                // and the weekday is quieter still.
                Text(DayHeaderText.day(date))
                    .typeRole(.dayNumber)
                    .foregroundStyle(Color.inkMuted)
                Text(DayHeaderText.monthAndYear(date))
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                Text(DayHeaderText.weekday(date))
                    .typeRole(.label)
                    .foregroundStyle(Color.inkFaint)
                Spacer(minLength: 4)
                if let ageMonths {
                    // How old he was, stated once for the day. Periwinkle, because it is a fact
                    // about the child rather than about the entries under it.
                    Text(AgeText.chip(ageMonths))
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.periwinkle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.periwinkleSoft, in: Capsule())
                }
            }
            .lineLimit(1)
            .padding(.top, yearDivider == nil ? 12 : 4)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, Layout.screenMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvas)
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let ageMonths else { return DayHeaderText.full(date) }
        return "\(DayHeaderText.full(date)). \(AgeText.spoken(ageMonths))"
    }

    private func yearRule(_ year: Int) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.border).frame(height: Layout.borderWidth)
            Text(String(year))
                .typeRole(.label)
                .foregroundStyle(Color.inkMuted)
            Rectangle().fill(Color.border).frame(height: Layout.borderWidth)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}
