import SwiftUI

/// The Today board, rendered from a `TodayBoard` and nothing else.
///
/// Deliberately free of networking, SwiftData and the model. `TodayScreen` owns all three and hands
/// this view a finished board, which is what makes all fifteen required states previewable — a
/// state you can only reach by flying somewhere with a bad signal is a state nobody ever looks at.
///
/// A `List` rather than the `ScrollView` this replaced, for one reason: `swipeActions` exists only
/// on `List`, and a hand-rolled drag gesture would fight the scroll view and be invisible to
/// VoiceOver. The list is styled back down to plain rows on the cream canvas.
struct TodayBoardView: View {
    let board: TodayBoard
    /// A quiet note over the board — an expired assignment, a dismissal that didn't reach the
    /// server. Never an error dialog over the parent's evening.
    var notice: String?
    /// A skip the parent can still take back. While this is set its row is already gone from
    /// `waiting`, because a row that stays put while a toast offers to undo it has not visibly
    /// done anything.
    var pendingSkip: String?

    var completedAt: (TodayBoard.BoardItem) -> Date? = { _ in nil }
    var failures: (TodayBoard.BoardItem) -> [Media] = { _ in [] }

    var onOpen: (TodayBoard.BoardItem) -> Void = { _ in }
    var onEdit: (TodayBoard.BoardItem) -> Void = { _ in }
    var onSkip: (TodayBoard.BoardItem) -> Void = { _ in }
    var onUndoSkip: () -> Void = {}
    var onDismissNotice: () -> Void = {}

    /// The one-time note shown on the first board after the trial ends.
    ///
    /// **Its own slot, not `notice`.** That string is the transport-and-expiry channel: it is
    /// overwritten by any `APIError` and cleared by `onDismissNotice`. Routing a once-ever
    /// presentation through it would let a dropped request either spend the flag or silently
    /// replace the sentence, and which one happened would depend on network timing.
    var membershipNotice: String?
    var onOpenMembership: () -> Void = {}
    var onDismissMembershipNotice: () -> Void = {}

    var onSwitchChild: (() -> Void)?
    /// TESTING ONLY — rebuilds today as one assignment per kind, because the real scheduler fills
    /// slots and cannot produce one of every kind on demand, which is what exercising the photo and
    /// video paths in one sitting actually needs. Goes before this ships, with the debug route
    /// behind it.
    var onResetBoard: (() -> Void)?
    var onRetry: (Media) -> Void = { _ in }
    var onRetryAll: (TodayBoard.BoardItem) -> Void = { _ in }

    var body: some View {
        List {
            header

            if let notice { noticeBanner(notice) }

            // **Above "Today", per the design's board order**, and below the transport notice — a
            // dropped request is about right now and outranks a note about the fortnight that just
            // ended.
            if let membershipNotice {
                Notice(
                    text: membershipNotice,
                    primaryLabel: MembershipCopy.postTrialOpen,
                    onPrimary: onOpenMembership,
                    onDismiss: onDismissMembershipNotice,
                    dismissLabel: MembershipCopy.postTrialDismiss
                )
                .plainRow()
            }

            // **One header over the live rows and the locked ones, because they are the same
            // day.**
            //
            // Emitted here rather than through `section(_:_:)` for a reason that is not tidiness:
            // that helper draws its header only when *its own* array is non-empty. With the locked
            // rows as a separate `ForEach` after it, the moment a free parent answered the daily
            // question `today` emptied into `doneToday`, the header disappeared, and the locked
            // cards were left floating above "Waiting" with nothing naming them — **which is the
            // state a free household is in for the rest of every day.** No artboard draws that.
            //
            // The locked rows still get **no header and no count of their own**: they are today's
            // slots, and a second quieter board is a place the eye learns to skip and a place a
            // count could one day be attached to. The copy file's first rule is that nothing
            // anywhere counts locked items.
            if board.showsTodaySection {
                BoardSectionHeader(title: "Today")
                    .plainRow(bottom: 10)

                // `failures`/`onEdit` are plumbed here for completeness rather than because this
                // section reaches them: `TodayBoard.merge` routes anything with a local entry into
                // `done_today`, so a card here is never done. `PromptCard` keeps its documented
                // done state — `design-system.md` specifies one — but on this board a finished item
                // becomes a `DoneCard`, which is where the retry list actually lives.
                ForEach(board.today) { item in
                    PromptCard(
                        item: item,
                        today: board.date,
                        onPrimary: { onOpen(item) },
                        onDismiss: { onSkip(item) },
                        onEdit: item.localEntryId == nil ? nil : { onEdit(item) },
                        failures: failures(item),
                        onRetry: onRetry,
                        onRetryAll: { onRetryAll(item) }
                    )
                    .plainRow()
                }

                // Below the live prompts, above `waiting`, in the order the server sent them.
                //
                // **No `swipeActions`.** The rows above have a skip; these must not. A lock you can
                // dismiss becomes a thing to dismiss every morning, and there is nothing to decline
                // — it was never offered.
                ForEach(board.locked) { locked in
                    LockedPromptCard(locked: locked, onOpenMembership: onOpenMembership)
                        .plainRow()
                }
            }

            section("Waiting", board.waiting, count: board.waiting.count) { item in
                WaitingCard(item: item, today: board.date, onOpen: { onOpen(item) })
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { onSkip(item) } label: {
                            Label("Skip", systemImage: "xmark")
                        }
                        // Never red. Skipping a prompt that does not fit this family is an
                        // ordinary thing to do, not a destructive one.
                        .tint(.inkMuted)
                    }
            }

            section("Done today", board.doneToday) { item in
                DoneCard(
                    item: item,
                    completedAt: completedAt(item),
                    onEdit: item.localEntryId == nil ? nil : { onEdit(item) },
                    failures: failures(item),
                    onRetry: onRetry,
                    onRetryAll: { onRetryAll(item) }
                )
            }

            if let mode = endOfBoard {
                AllCaughtUpCard(mode: mode)
                    .plainRow()
            }

            // The toast floats over the board, so the last row needs somewhere to end that is not
            // underneath it. Scaled, because the toast is two lines of body text plus a capsule and
            // grows to roughly three times this at accessibility sizes — a fixed gap would leave the
            // bottom of the board permanently covered for the people least able to work around it.
            Color.clear
                .frame(height: pendingSkip == nil ? 8 : toastClearance)
                .plainRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .animation(Motion.cardToDone, value: board.waiting.map(\.id))
        .animation(Motion.cardToDone, value: board.doneToday.map(\.id))
        .overlay(alignment: .bottom) {
            if let pendingSkip {
                SkipToast(text: pendingSkip, onUndo: onUndoSkip)
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // The toast is a sibling placed after every row in the accessibility tree, so
                    // without this a VoiceOver user is never told it exists and the undo window
                    // closes on an offer they could not hear. Sort priority pulls it to the front
                    // of the screen's reading order for as long as it is up.
                    .accessibilitySortPriority(1)
            }
        }
        .animation(Motion.cardToDone, value: pendingSkip)
        .onChange(of: pendingSkip) { _, text in
            guard let text else { return }
            AccessibilityNotification.Announcement("\(text). Undo available.").post()
        }
    }

    /// Runway under the last row while the toast is up.
    @ScaledMetric(relativeTo: .body) private var toastClearance: CGFloat = 76

    // MARK: Zones

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                ChildSwitcherPill(name: board.child.name, onSelect: onSwitchChild)
                Text(AgeText.greeting(board.child.ageMonths))
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)

            if let onResetBoard {
                Button(action: onResetBoard) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.inkMuted)
                        .padding(9)
                        .background(Color.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
                }
                .buttonStyle(TapScaleButtonStyle())
                .accessibilityLabel("Refresh")
            }
        }
        .padding(.top, 4)
        .plainRow()
    }

    /// Sections with nothing in them are not rendered at all — never an empty labelled shell.
    @ViewBuilder
    private func section(
        _ title: String,
        _ items: [TodayBoard.BoardItem],
        count: Int? = nil,
        @ViewBuilder row: @escaping (TodayBoard.BoardItem) -> some View
    ) -> some View {
        if !items.isEmpty {
            BoardSectionHeader(title: title, count: count)
                .plainRow(bottom: 10)

            // No per-row `.transition` here: `List` animates its own insertions and removals
            // from the backing collection view and ignores one. The `.animation` on the list
            // keyed to the row ids above is what actually moves a card into Done today.
            ForEach(items) { item in
                row(item).plainRow()
            }
        }
    }

    private var endOfBoard: AllCaughtUpCard.Mode? {
        .forBoard(
            today: board.today.count,
            waiting: board.waiting.count,
            doneToday: board.doneToday.count,
            locked: board.locked.count
        )
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.inkMuted)
                .accessibilityHidden(true)
            Text(text).typeRole(.metadata).foregroundStyle(Color.inkMuted)
            Spacer(minLength: 0)
            Button("Dismiss", action: onDismissNotice)
                .typeRole(.metadata)
                .foregroundStyle(Color.terracotta)
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
        .plainRow()
    }
}

/// Small-caps label, an optional count, and the hairline under both.
struct BoardSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SectionLabel(title)
                // A count, not an accusation. There is no streak counter anywhere in this app.
                if let count, count > 0 {
                    Chip(text: "\(count) waiting")
                }
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(Color.border)
                .frame(height: Layout.borderWidth)
        }
    }
}

/// "Skipped …" with an Undo, over the board.
///
/// The undo is the whole reason the skip is allowed to be a swipe. There is no un-dismiss endpoint
/// — `POST /assignments/{id}/dismiss` is one-way — so the request is simply not sent until this
/// toast has come and gone. See `TodayModel.skip(_:)`.
struct SkipToast: View {
    let text: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .typeRole(.body)
                .foregroundStyle(Color.surface.opacity(0.92))
                .lineLimit(2)

            Spacer(minLength: 0)

            Button("Undo", action: onUndo)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.terracottaSoft)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.surface.opacity(0.16), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(Color.ink, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// A list row that looks nothing like a list row: no separator, no chrome, no fill.
    func plainRow(bottom: CGFloat = Layout.cardSpacing) -> some View {
        listRowInsets(EdgeInsets(
            top: 0, leading: Layout.screenMargin, bottom: bottom, trailing: Layout.screenMargin
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
