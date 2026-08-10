import SwiftData
import SwiftUI

@MainActor
@Observable
final class TodayModel {
    enum State: Equatable {
        case loading
        case loaded(TodayResponse)
        case failed(String)

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.loading, .loading): true
            case (.loaded(let x), .loaded(let y)): x.date == y.date && x.today.count == y.today.count
            case (.failed(let x), .failed(let y)): x == y
            default: false
            }
        }
    }

    /// A skip the parent can still take back.
    ///
    /// **The request is not sent while this is set.** There is no un-dismiss endpoint —
    /// `POST /assignments/{id}/dismiss` is one-way, and `POST /assignments/{id}/custom` only
    /// resurrects a row by overwriting its body and flipping `is_custom` permanently, which would
    /// be the client corrupting a row to fake an undo. So the honest version of the design's toast
    /// is to hold the request for the toast's life and send it only if Undo is not tapped.
    ///
    /// If the app dies inside the window the skip is simply lost and the prompt stays on the
    /// board. That is the safe direction to fail: nothing is deleted that the parent cannot see.
    struct PendingSkip: Equatable {
        let assignment: AssignmentResponse

        var label: String {
            let body = assignment.body
            // Sentences end in more than a full stop. A quarter of the seeded library asks a
            // question, and splitting on "." alone runs those straight into the next sentence.
            let end = body.firstIndex { ".?!".contains($0) }
            let firstSentence = end.map { String(body[body.startIndex..<$0]) } ?? body
            let trimmed = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = trimmed.count > 60
                ? trimmed.prefix(57).trimmingCharacters(in: .whitespaces) + "…"
                : trimmed
            return "Skipped “\(shown)”"
        }
    }

    private(set) var state: State = .loading
    /// A quiet, non-alarming note shown over the board — an expired assignment, a dismissal
    /// that didn't reach the server. Never an error dialog over the parent's work.
    var notice: String?
    private(set) var pendingSkip: PendingSkip?

    /// Every assignment the parent has swiped away and not taken back — the one still inside its
    /// window, plus any whose request is in flight.
    ///
    /// The board filters on this rather than on `pendingSkip` alone. A second skip inside the first
    /// one's window commits the first, which clears `pendingSkip` — and if that were the only thing
    /// hiding it, the first row would pop back onto the board for as long as the request took, in
    /// front of the parent who just watched it leave.
    private(set) var hiddenSkips: Set<UUID> = []

    /// How long Undo stays on screen.
    ///
    /// Eight seconds, not the five a toast usually gets. VoiceOver has to finish announcing the
    /// toast before anyone can act on it, and a parent reaching a button one-handed with a child on
    /// the other arm is the ordinary case here rather than the accessible edge one. Injectable so
    /// the tests do not have to spend eight seconds proving it.
    let skipGrace: Duration

    private var skipTask: Task<Void, Never>?
    private let childId: UUID
    private let api: APIClient

    init(childId: UUID, api: APIClient, skipGrace: Duration = .seconds(8)) {
        self.childId = childId
        self.api = api
        self.skipGrace = skipGrace
    }

    func load(showSpinner: Bool = true) async {
        if showSpinner, case .loaded = state {} else if showSpinner { state = .loading }
        do {
            state = .loaded(try await api.today(childId: childId))
        } catch let error as APIError {
            // A refetch failing over an already-loaded board should not blank it.
            if case .loaded = state { notice = error.userMessage } else { state = .failed(error.userMessage) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Skipping

    /// Hide the row now, send the request when the window closes.
    func skip(_ assignment: AssignmentResponse) {
        // One toast at a time. A second skip commits the first rather than dropping it — the
        // parent saw that row leave and it must not come back.
        if let previous = pendingSkip {
            skipTask?.cancel()
            skipTask = nil
            pendingSkip = nil
            Task { await self.send(previous.assignment) }
        }

        hiddenSkips.insert(assignment.id)
        pendingSkip = PendingSkip(assignment: assignment)

        let window = skipGrace
        skipTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.flushPendingSkip()
        }
    }

    func undoSkip() {
        skipTask?.cancel()
        skipTask = nil
        if let pending = pendingSkip { hiddenSkips.remove(pending.assignment.id) }
        pendingSkip = nil
    }

    /// The window elapsed. Hand the send to a **fresh** task and return.
    ///
    /// The subtle part, and the reason this is not just a call to `commitPendingSkip()`: this runs
    /// *inside* `skipTask`. Cancelling that task — which committing has to do, so an external
    /// commit stops the timer — would cancel the very task the request was about to be made on, and
    /// `URLSession`'s async API honours cancellation. The dismissal would fail with a cancellation
    /// error every single time the window simply ran out, which is the ordinary path. A stub
    /// performer never notices; a phone does.
    private func flushPendingSkip() {
        guard let pending = pendingSkip else { return }
        skipTask = nil
        pendingSkip = nil
        Task { await self.send(pending.assignment) }
    }

    /// Send the held request now — the app is going to the background, or the screen is going away.
    ///
    /// Safe to call from outside the timer: it cancels the timer and sends on the caller's task.
    func commitPendingSkip() async {
        guard let pending = pendingSkip else { return }
        skipTask?.cancel()
        skipTask = nil
        pendingSkip = nil
        await send(pending.assignment)
    }

    private func send(_ assignment: AssignmentResponse) async {
        defer { hiddenSkips.remove(assignment.id) }
        do {
            try await api.dismissAssignment(assignment.id)
            // Refetch before un-hiding: the server has moved the row to `dismissed`, so the board
            // that comes back no longer holds it and the row never flickers back into view.
            await load(showSpinner: false)
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }
}

struct TodayScreen: View {
    let childId: UUID
    let api: APIClient
    /// Stamped onto the widget snapshot. This screen never computes a date with it — the server
    /// already named the day, and the zone travels alongside so the *widget* can ask later
    /// whether that day is still the current one.
    let familyTimezone: String
    /// An assignment the widget asked to open. Resolved against the board below and cleared
    /// either way, because an id this board does not hold must leave the parent on Today rather
    /// than in a composer for nothing.
    var requestedAssignment: Binding<UUID?> = .constant(nil)
    var onRetrySync: () -> Void = {}
    /// Runs the push-then-pull sweep. One of the four triggers, and the boring one: opening the
    /// screen a parent opens most is a good moment to be up to date.
    var onSync: () async -> Void = {}
    let openComposer: (ComposerRequest) -> Void

    /// **Owned by `RootView`, not by this screen.** The tab switch destroys this view, and the
    /// widget's snapshot has to keep up with the archive from two tabs away — so the model, and
    /// the publishing that reads it, live above the tab. See `WidgetSnapshotSync`.
    let model: TodayModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    /// Local completions and their media, merged over the server's board every render.
    /// Queried rather than held, so this survives a relaunch — the board is rebuilt from
    /// SwiftData, not from anything remembered in memory.
    @Query(filter: #Predicate<Entry> { $0.deletedAt == nil }) private var localEntries: [Entry]
    @Query(filter: #Predicate<Media> { $0.deletedAt == nil }) private var localMedia: [Media]

    var body: some View {
        content
            .background(Color.canvas)
            .refreshable { await model.load(showSpinner: false) }
            .task {
                await model.load()
                await onSync()
            }
            // Refetch on foreground: the server owns what day it is, so a phone left open
            // overnight must not keep showing yesterday's board.
            //
            // Going to the *background* also commits a held skip: a parent who swipes and then
            // leaves has decided, and the toast is not coming back for them to confirm it.
            //
            // `.background` specifically, not "anything that is not active". iOS delivers
            // `.inactive` for a pulled-down notification, Control Center, the app switcher, a
            // screenshot and an incoming call — ending someone's undo window because a banner
            // slid down is taking the decision away from them.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await model.load(showSpinner: false) }
                case .background: Task { await model.commitPendingSkip() }
                default: break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().tint(.terracotta).padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Text("Can't load today")
                    .typeRole(.title).foregroundStyle(Color.ink)
                Text(message)
                    .typeRole(.body).foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, Layout.screenMargin)
            .padding(.top, 50)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .loaded(let response):
            // The merge happens here rather than in the model so it re-runs whenever SwiftData
            // changes — saving an entry updates the board without waiting for a refetch.
            let board = visibleBoard(from: response)
            TodayBoardView(
                board: board,
                notice: model.notice,
                pendingSkip: model.pendingSkip?.label,
                completedAt: completedAt,
                failures: failures,
                onOpen: { open($0.assignment) },
                onEdit: { item in
                    if let entryId = item.localEntryId { edit(entryId: entryId) }
                },
                onSkip: { model.skip($0.assignment) },
                onUndoSkip: { model.undoSkip() },
                onDismissNotice: { model.notice = nil },
                // Debug builds only. The `/debug/*` route behind it is registered only when the
                // API runs with ENVIRONMENT=local, so in a release build this button is a 404
                // wearing a refresh icon.
                onResetBoard: debugResetBoard,
                onRetry: { retry([$0]) },
                onRetryAll: { retry(failures($0)) }
            )
            .onChange(of: requestedAssignment.wrappedValue, initial: true) { _, id in
                openRequested(id, on: board)
            }
        }
    }

    /// The merged board, with any row the parent has just swiped away already gone.
    ///
    /// Hidden rather than marked, because a row that sits there greyed out while a toast offers to
    /// undo it has not visibly done anything, and the parent taps the swipe again.
    private func visibleBoard(from response: TodayResponse) -> TodayBoard {
        var board = TodayBoard.merge(response: response, entries: localEntries, media: localMedia)
        let hidden = model.hiddenSkips
        guard !hidden.isEmpty else { return board }
        board.today = board.today.filter { !hidden.contains($0.id) }
        board.waiting = board.waiting.filter { !hidden.contains($0.id) }
        return board
    }

    /// When the entry behind a done card actually happened. **`occurredAt`, never `createdAt`** —
    /// backdating is a first-class flow and the done row must say the evening it belongs to.
    private func completedAt(_ item: TodayBoard.BoardItem) -> Date? {
        guard let entryId = item.localEntryId else { return nil }
        return localEntries.first { $0.id == entryId }?.occurredAt
    }

    /// Media cards open too. The Today screen must not lie about what the scheduler served, so
    /// they render and are tappable — the composer says capture is coming rather than the card
    /// quietly not existing.
    private func open(_ assignment: AssignmentResponse) {
        openComposer(
            ComposerRequest(childId: childId, assignment: assignment, mode: assignment.completion)
        )
    }

    /// Open what the widget was tapped on.
    ///
    /// **Cleared before anything else happens, and unconditionally.** The one outcome that has to
    /// be impossible is a composer opened for an assignment this board does not hold, and the
    /// second is a request that survives its own failure and re-fires on the next render. An id
    /// that resolves to nothing leaves the parent on Today, which is where they already are.
    ///
    /// A finished item opens the entry it produced rather than a second composer for the same
    /// assignment — cheap, because Today already edits a done card that way.
    private func openRequested(_ id: UUID?, on board: TodayBoard) {
        guard let id else { return }
        requestedAssignment.wrappedValue = nil

        switch board.route(forAssignment: id) {
        case .composer(let assignment): open(assignment)
        case .entry(let entryId): edit(entryId: entryId)
        case .today: break
        }
    }

    /// Tapping a done card edits the entry behind it.
    private func edit(entryId: UUID) {
        guard let entry = localEntries.first(where: { $0.id == entryId }) else { return }
        openComposer(
            ComposerRequest(
                childId: childId,
                assignment: nil,
                mode: entry.body?.isEmpty == false ? .text : .didIt,
                editing: entry.id
            )
        )
    }

    /// Files on this card that need a decision. Listed individually, never summarised.
    private func failures(_ item: TodayBoard.BoardItem) -> [Media] {
        guard let entryId = item.localEntryId else { return [] }
        return localMedia.filter { $0.entryId == entryId && $0.state == .failed }
    }

    /// The board-reset affordance, or nil outside a debug build.
    private var debugResetBoard: (() -> Void)? {
        #if DEBUG
        { Task { await resetBoard() } }
        #else
        nil
        #endif
    }

    /// Rebuild the board, then refetch. Failures surface in the same quiet notice the rest of
    /// the screen uses rather than a dialog — it is a test affordance, not a user feature.
    private func resetBoard() async {
        do {
            let result = try await api.resetBoard(childId: childId)
            await model.load(showSpinner: false)
            if !result.unavailable.isEmpty {
                model.notice = "No active prompt for: \(result.unavailable.joined(separator: ", "))"
            }
        } catch let error as APIError {
            model.notice = error.userMessage
        } catch {
            model.notice = error.localizedDescription
        }
        onRetrySync()
    }

    private func retry(_ media: [Media]) {
        for row in media { row.resetForManualRetry() }
        try? context.save()
        onRetrySync()
    }
}
