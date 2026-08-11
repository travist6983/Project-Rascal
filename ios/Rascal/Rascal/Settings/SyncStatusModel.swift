import Foundation
import SwiftUI

/// What the sync-pull rows in Settings show, and the two actions they can take.
///
/// Separate from `SyncEngine` because the engine's job is correctness and this one's job is
/// wording. Everything here is a sentence a parent reads — "Everything's up to date", not a
/// cursor — and none of it is computed anywhere the engine can see.
@MainActor
@Observable
final class SyncStatusModel {

    enum DryRunState: Equatable {
        case idle
        case running
        /// One line for the card. The full report is behind `report`.
        case ready(String)
        case failed(String)
    }

    private(set) var dryRun: DryRunState = .idle
    /// The full report, for the sheet and for the clipboard.
    private(set) var report: String?
    /// Bumped whenever the engine's stored state changes, so the rows re-read it. The engine
    /// keeps its position outside SwiftData, so there is no `@Query` to do this for us.
    private(set) var revision = 0

    private let engine: SyncEngine

    init(engine: SyncEngine) {
        self.engine = engine
    }

    var isBusy: Bool { dryRun == .running }

    // MARK: The switch

    /// Reading `revision` inside the getter is what makes the row redraw after a reset or a
    /// pull — the value lives in UserDefaults, which publishes nothing.
    var pullEnabledBinding: Binding<Bool> {
        Binding(
            get: { [engine] in _ = self.revision; return engine.pullEnabled },
            set: { [engine] newValue in
                engine.pullEnabled = newValue
                self.revision += 1
            }
        )
    }

    // MARK: The rows

    /// When the last pull actually succeeded.
    ///
    /// **This row's value is a time, and it never says anything else.** It used to fall back to
    /// `pullEnabled ? "Not yet" : "Off"`, so a row labelled "Last pull" rendered the *feature's*
    /// on/off state where a timestamp belongs — "Last pull — Off" is not a wrong time, it is not
    /// a time at all, and it was the reason to distrust every other number on the card.
    ///
    /// Three states, all of them about when: a real relative time, "Never", or "Never" plus the
    /// reason it cannot have happened. The last one matters because with pulling off the row is
    /// otherwise an empty fact a parent has no way to interpret.
    var lastPullDescription: String {
        _ = revision
        guard let last = engine.lastSuccess else {
            return engine.pullEnabled ? "Never" : "Never — pulling is off"
        }
        return Self.relative(last)
    }

    /// The stored position, said plainly. Nil hides the row rather than showing an empty one.
    var cursorDescription: String? {
        _ = revision
        guard let cursor = engine.cursor else {
            return engine.pullEnabled ? "Nothing stored — the next sync reads everything" : nil
        }
        return Self.absolute(cursor)
    }

    var lastErrorDescription: String? {
        _ = revision
        return engine.lastError
    }

    var reportTitle: String { "Dry run" }

    // MARK: Actions

    func runDryRun() async {
        guard dryRun != .running else { return }
        dryRun = .running
        report = nil

        let outcome = await engine.dryRun()
        revision += 1

        switch outcome {
        case .completed(let plan):
            report = plan.report()
            dryRun = .ready(Self.summarise(plan))
        case .failed(let failure):
            // The partial plan is still worth keeping: it says how far the run got before the
            // network gave out, which is more useful than the message on its own.
            report = failure.plan?.report()
            dryRun = .failed(failure.message)
        case .disabled:
            // Unreachable — a dry run ignores the flag — and handled rather than defaulted, so a
            // future case cannot land here silently.
            dryRun = .failed("The dry run did not run.")
        }
    }

    func resetCursor() {
        engine.resetCursor()
        revision += 1
    }

    // MARK: Wording

    /// The one line on the card. Says what would change, and names the deletions separately
    /// because they are the thing worth reading before anything else.
    static func summarise(_ plan: SyncPlan) -> String {
        guard !plan.isNoOp else {
            return "Nothing to change — this device already has everything the server sent."
        }
        var parts: [String] = []
        let inserts = plan.count(.insert)
        let updates = plan.count(.update)
        let deletes = plan.count(.softDelete)
        if inserts > 0 { parts.append("\(inserts) to add") }
        if updates > 0 { parts.append("\(updates) to update") }
        if deletes > 0 { parts.append("\(deletes) to remove") }

        var sentence = parts.joined(separator: ", ") + "."
        let skipped = plan.count(.skippedLocalPending)
        if skipped > 0 {
            sentence += " \(skipped) left alone because this phone has newer changes."
        }
        if !plan.anomalies.isEmpty {
            sentence += " \(plan.anomalies.count) it didn't understand — read the report."
        }
        return sentence
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
