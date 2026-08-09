import Foundation

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

    /// Runs the correction, then pulls so the corrected values reach the local mirror.
    ///
    /// The pull is not optional. The server writes only changed rows, which is what keeps the
    /// correction out of every other client's sync cursor — but it also means this device's
    /// cached ages are stale the instant the call returns, and the screen that shows them is one
    /// tab away.
    func run(sync: EntrySync?) async {
        guard !isRunning else { return }
        state = .running

        do {
            let result = try await api.recomputeAges(childId: childId)
            state = .done(updated: result.entriesUpdated, birthdate: result.birthdate)
            await sync?.sweep()
        } catch let error as APIError {
            state = .failed(Self.explain(error))
        } catch {
            state = .failed(error.localizedDescription)
        }
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
