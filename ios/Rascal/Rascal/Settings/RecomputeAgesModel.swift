import Foundation
import SwiftData

/// The birthdate correction, made explicit.
///
/// `entries.child_age_months` is computed at write and stored, so that fixing a typo in a
/// birthdate does not silently reshape an archive. The cost of that decision is that the typo is
/// otherwise permanent, and this is the escape hatch it requires — **deliberate, user-invoked,
/// and never a side effect of saving the birthdate.**
///
/// It is a repair tool, so the copy is factual rather than cautionary. Nothing is destroyed and
/// nothing is at risk: the server recomputes each entry from its own `occurred_at`, writes only
/// the rows that actually change, and is idempotent — a second run reports zero.
@MainActor
@Observable
final class RecomputeAgesModel {

    enum State: Equatable {
        case idle
        case running
        /// How many rows actually changed, and the birthdate they were recomputed against.
        case done(updated: Int, birthdate: String)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let childId: UUID
    private let api: APIClient

    init(childId: UUID, api: APIClient) {
        self.childId = childId
        self.api = api
    }

    var isRunning: Bool { state == .running }

    /// Runs the correction, then refreshes what it can of the local mirror.
    ///
    /// **This is a partial refresh, and the limit is worth stating.** Every cached entry's
    /// `child_age_months` is stale the instant the server returns, and the proper mechanism for
    /// carrying that down is `GET /sync` — which is exactly why the server writes only the rows
    /// that changed. This client has no `/sync` yet: `EntrySync` pushes local writes and pulls
    /// nothing, so calling its sweep here would look like a refresh and move no ages at all.
    ///
    /// So it re-reads the newest page instead. That corrects the entries a parent is most likely
    /// to look at straight after doing this, immediately; the rest correct as the timeline
    /// reconciles, which it does on pull-to-refresh and as pages load. Recorded in
    /// `docs/blocked.md` — a full correction across an eighteen-year archive is `/sync`'s job and
    /// re-paging the whole thing here would undo the point of the server writing only what moved.
    func run(context: ModelContext?) async {
        guard !isRunning else { return }
        state = .running

        do {
            let result = try await api.recomputeAges(childId: childId)
            state = .done(updated: result.entriesUpdated, birthdate: result.birthdate)
            await refreshNewestPage(into: context)
        } catch let error as APIError {
            state = .failed(Self.explain(error))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// One request. Best effort: a correction that landed on the server is not undone by a
    /// refresh that did not, and the screen already says what changed.
    private func refreshNewestPage(into context: ModelContext?) async {
        guard let context else { return }
        guard let page = try? await api.entries(childId: childId, limit: TimelineModel.pageSize)
        else { return }
        EntryCache.upsert(page.entries, into: context)
    }

    func dismiss() {
        state = .idle
    }

    /// Plain and quantified. "Nothing needed changing" is a real, common outcome — the ages were
    /// already right — and it must not read as a failure.
    static func summary(updated: Int, birthdate: String) -> String {
        switch updated {
        case 0: "Nothing needed changing. Every age already matched \(birthdate)."
        case 1: "1 entry updated to match \(birthdate)."
        default: "\(updated) entries updated to match \(birthdate)."
        }
    }

    private static func explain(_ error: APIError) -> String {
        switch error.code {
        case .notAuthorized:
            "Only a parent on this archive can do this."
        case .notFound:
            "That archive is no longer here."
        default:
            error.userMessage
        }
    }
}
