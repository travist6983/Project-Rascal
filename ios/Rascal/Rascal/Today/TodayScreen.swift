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

        /// **Takes the subject rather than reading one**, because this is a model type inside an
        /// `@Observable` and there is no environment here to read. The toast quotes a prompt back
        /// at the parent, so it has to be the same sentence the card was showing a moment ago —
        /// and truncating before substituting would count the braces towards the 60.
        /// `personalized` is the string the card was actually showing, when there is one. Applied
        /// **before** the truncation for the same reason the substitution is: shortening first and
        /// personalizing after would count the library's words towards the 60 and then quote back
        /// a sentence the parent never saw.
        func label(for subject: PromptSubject, personalized: String? = nil) -> String {
            let body = personalized ?? PromptTokens.render(assignment.body, for: subject)
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

    /// The once-ever note shown on the first board after the trial ends.
    ///
    /// **Its own property, not `notice`.** That one is the transport channel and is overwritten by
    /// any `APIError`; a once-ever presentation sharing it would be spent or silently replaced by
    /// network timing.
    private(set) var membershipNotice: String?

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
    /// What this device has already shown about membership. Injected so the once-ever rules can be
    /// driven in a test without touching `UserDefaults`.
    private let presentation: MembershipPresentationStoring

    init(
        childId: UUID,
        api: APIClient,
        skipGrace: Duration = .seconds(8),
        presentation: MembershipPresentationStoring = UserDefaultsMembershipPresentationStore()
    ) {
        self.childId = childId
        self.api = api
        self.skipGrace = skipGrace
        self.presentation = presentation
    }

    func load(showSpinner: Bool = true) async {
        if showSpinner, case .loaded = state {} else if showSpinner { state = .loading }
        do {
            let response = try await api.today(childId: childId)
            observe(response.access)
            state = .loaded(response)
        } catch let error as APIError {
            // A refetch failing over an already-loaded board should not blank it.
            if case .loaded = state { notice = error.userMessage } else { state = .failed(error.userMessage) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Decide the once-ever notice, then record what was seen.
    ///
    /// **Called only from a response that actually decoded**, which is the whole of its correctness.
    /// A network error or a decode failure must not reach this: writing an assumed value into
    /// `lastObservedAccess` would record an observation that never happened, and the next genuine
    /// `free` would then look like a flip from something.
    ///
    /// The order matters too — read the record, then update it. Observing first would overwrite the
    /// `trial` this is looking for with the `free` that arrived, and the notice would never fire.
    private func observe(_ access: Access) {
        var record = presentation.load()

        if MembershipPresentation.shouldShowPostTrialNotice(record: record, access: access) {
            membershipNotice = MembershipCopy.postTrialNotice
            // **Spent on being shown, not on being dismissed.** Seeing it is what spends it; a
            // notice that comes back because the parent scrolled past instead of tapping Dismiss is
            // the nag the copy rules forbid.
            record.postTrialNoticeShown = true
        }

        presentation.save(MembershipPresentation.observing(access, in: record))
    }

    /// The parent tapped Dismiss. The flag was already spent when it was shown, so this only takes
    /// it off the screen.
    func dismissMembershipNotice() {
        membershipNotice = nil
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
    /// Open the child switcher. Nil with one child, which is what keeps the pill a label — see
    /// `ChildSwitcherPill`. Passed down untouched; this screen does not decide the condition.
    var onSwitchChild: (() -> Void)?
    /// Runs the push-then-pull sweep. One of the four triggers, and the boring one: opening the
    /// screen a parent opens most is a good moment to be up to date.
    var onSync: () async -> Void = {}
    let openComposer: (ComposerRequest) -> Void

    /// The one instance, owned by `RootView`. Nil for the first frame while it is built, which is
    /// the same shape every other model handed down here has — a locked card tapped in that beat
    /// simply does not open a sheet, rather than opening an empty one.
    var subscription: SubscriptionModel?

    /// **Owned by `RootView`, not by this screen.** The tab switch destroys this view, and the
    /// widget's snapshot has to keep up with the archive from two tabs away — so the model, and
    /// the publishing that reads it, live above the tab. See `WidgetSnapshotSync`.
    let model: TodayModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingMembership = false
    @Environment(\.modelContext) private var context
    /// The child every prompt on this board is about.
    @Environment(\.promptSubject) private var promptSubject
    @Environment(\.personalization) private var personalization

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
            // **A sheet, not a `fullScreenCover`.** The copy file and the phase brief agree: this is
            // a door. A cover would be an interstitial the parent has to beat to get back to the
            // board they opened the app for.
            //
            // Presented from here rather than from the card, because `TodayBoardView` is a `List`
            // and a sheet owned by a row is torn down whenever the row is recycled.
            .sheet(isPresented: $showingMembership) {
                if let subscription {
                    PaywallSheet(model: subscription) { showingMembership = false }
                }
            }
            // **A locked card cannot open a sheet that does not exist yet.** `subscription` is nil
            // only for the first frame while `RootView` builds it; without this the sheet would
            // present empty and the parent would have to dismiss a blank one.
            .onChange(of: subscription == nil) { _, isMissing in
                if isMissing { showingMembership = false }
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
                pendingSkip: model.pendingSkip.map {
                    $0.label(
                        for: promptSubject,
                        personalized: personalization.text(
                            for: $0.assignment.id,
                            canonical: PromptTokens.render($0.assignment.body, for: promptSubject)
                        )
                    )
                },
                completedAt: completedAt,
                failures: failures,
                onOpen: { open($0.assignment) },
                onEdit: { item in
                    if let entryId = item.localEntryId { edit(entryId: entryId) }
                },
                onSkip: { model.skip($0.assignment) },
                onUndoSkip: { model.undoSkip() },
                onDismissNotice: { model.notice = nil },
                membershipNotice: model.membershipNotice,
                onOpenMembership: { showingMembership = true },
                onDismissMembershipNotice: { model.dismissMembershipNotice() },
                onSwitchChild: onSwitchChild,
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
        // **`localEntries` is every child's, so it is narrowed here.** The queries above cannot
        // carry the child — a `@Query` predicate is fixed at init, and capturing a property means
        // a hand-written `init` re-declaring five defaulted parameters for no gain. The merge
        // binds entries to cards by assignment id, which is unique per row, so a sibling's entry
        // cannot key into this board even unfiltered; this makes that a stated constraint rather
        // than a property of UUIDs. `media` stays whole: it has no `childId` and is grouped by
        // `entryId` off these now-scoped entries.
        var board = TodayBoard.merge(
            response: response,
            entries: localEntries.filter { $0.childId == childId },
            media: localMedia
        )
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
        openComposer(ComposerRequest.editing(entry, in: localMedia, childId: childId))
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
