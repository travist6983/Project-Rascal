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

    private(set) var state: State = .loading
    /// A quiet, non-alarming note shown over the board — an expired assignment, a dismissal
    /// that didn't reach the server. Never an error dialog over the parent's work.
    var notice: String?

    private let childId: UUID
    private let api: APIClient

    init(childId: UUID, api: APIClient) {
        self.childId = childId
        self.api = api
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

    func dismiss(_ assignment: AssignmentResponse) async {
        do {
            try await api.dismissAssignment(assignment.id)
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
    var onRetrySync: () -> Void = {}
    let openComposer: (ComposerRequest) -> Void

    @State private var model: TodayModel?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    /// Local completions and their media, merged over the server's board every render.
    /// Queried rather than held, so this survives a relaunch — the board is rebuilt from
    /// SwiftData, not from anything remembered in memory.
    @Query(filter: #Predicate<Entry> { $0.deletedAt == nil }) private var localEntries: [Entry]
    @Query(filter: #Predicate<Media> { $0.deletedAt == nil }) private var localMedia: [Media]

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Layout.screenMargin)
                .padding(.top, 8)
        }
        .background(Color.canvas)
        .refreshable { await model?.load(showSpinner: false) }
        .task {
            if model == nil { model = TodayModel(childId: childId, api: api) }
            await model?.load()
        }
        // Refetch on foreground: the server owns what day it is, so a phone left open
        // overnight must not keep showing yesterday's board.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model?.load(showSpinner: false) } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .loading {
        case .loading:
            ProgressView().tint(.terracotta).padding(.top, 60)

        case .failed(let message):
            VStack(spacing: 12) {
                Text("Can't load today")
                    .typeRole(.title).foregroundStyle(Color.ink)
                Text(message)
                    .typeRole(.body).foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model?.load() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 50)

        case .loaded(let response):
            // The merge happens here rather than in the model so it re-runs whenever SwiftData
            // changes — saving an entry updates the board without waiting for a refetch.
            let board = TodayBoard.merge(response: response, entries: localEntries, media: localMedia)
            VStack(alignment: .leading, spacing: 22) {
                greeting(board.child)
                if let notice = model?.notice { noticeBanner(notice) }
                section("Today", board.today)
                section("Waiting", board.waiting, count: board.waiting.count)
                section("Done today", board.doneToday)
                if board.today.isEmpty && board.waiting.isEmpty && board.doneToday.isEmpty {
                    allCaughtUp
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func greeting(_ child: ChildSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(child.name)
                .typeRole(.display)
                .foregroundStyle(Color.ink)
            Text(ageText(child.ageMonths))
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    /// Read from the server's `age_months`, never computed from a birthdate here.
    private func ageText(_ months: Int) -> String {
        let years = months / 12, rest = months % 12
        if years == 0 { return "\(months) month\(months == 1 ? "" : "s") old" }
        if rest == 0 { return "\(years) year\(years == 1 ? "" : "s") old" }
        return "\(years)y \(rest)m"
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TodayBoard.BoardItem], count: Int? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                HStack(spacing: 8) {
                    SectionLabel(title)
                    // A count, not an accusation. There is no streak counter anywhere.
                    if let count, count > 0 {
                        Chip(text: "\(count) waiting")
                    }
                }
                ForEach(items) { item in
                    PromptCard(
                        item: item,
                        onPrimary: { open(item.assignment) },
                        onDismiss: { Task { await model?.dismiss(item.assignment) } },
                        onEdit: item.localEntryId.map { id in { edit(entryId: id) } },
                        failures: failures(for: item),
                        onRetry: { retry([$0]) },
                        onRetryAll: { retry(failures(for: item)) }
                    )
                    .transition(Motion.listInsert)
                }
            }
            .animation(Motion.cardToDone, value: items.map(\.id))
        }
    }

    private var allCaughtUp: some View {
        VStack(spacing: 10) {
            Text("Nothing waiting")
                .typeRole(.title).foregroundStyle(Color.ink)
            Text("Today's prompts arrive in the morning.")
                .typeRole(.body).foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Gradients.wash, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.inkMuted)
            Text(text).typeRole(.metadata).foregroundStyle(Color.inkMuted)
            Spacer(minLength: 0)
            Button("Dismiss") { model?.notice = nil }
                .typeRole(.metadata)
                .foregroundStyle(Color.terracotta)
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
    }

    /// Media cards open too. The Today screen must not lie about what the scheduler served, so
    /// they render and are tappable — the composer says capture is coming rather than the card
    /// quietly not existing.
    private func open(_ assignment: AssignmentResponse) {
        openComposer(
            ComposerRequest(childId: childId, assignment: assignment, mode: assignment.completion)
        )
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
    private func failures(for item: TodayBoard.BoardItem) -> [Media] {
        guard let entryId = item.localEntryId else { return [] }
        return localMedia.filter { $0.entryId == entryId && $0.state == .failed }
    }

    private func retry(_ media: [Media]) {
        for row in media { row.resetForManualRetry() }
        try? context.save()
        onRetrySync()
    }
}
