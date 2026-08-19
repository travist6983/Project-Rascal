import Foundation
import SwiftData

/// One upload, as the per-file list sees it.
///
/// **"10 files stopped trying" with no way to see which ten is not something a parent can act on.**
/// The count was the only surface these rows had outside Today — and Today only shows failures for
/// entries that complete an assignment on the board, so a freeform or backfilled entry's failed
/// media had no surface at all.
struct SyncUploadRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let entryId: UUID
    /// "audio", "photo", "video" — the row's own `kind`, not a guess from its extension.
    let kind: String
    let state: MediaUploadState
    let byteCount: Int
    let attemptCount: Int
    /// False when the staged original is gone. **A row that cannot be retried at all**, and the
    /// list has to say so rather than offering the same action for both.
    let hasBytes: Bool

    /// No upload failure reason, deliberately unfaked. `Media` carries `transcriptFailure` for the
    /// transcript leg and has no equivalent for uploads, so the last error is genuinely not
    /// persisted anywhere. Inventing a column for it is a schema change and belongs in its own
    /// phase, not smuggled into a screen.
    var stateLabel: String {
        switch state {
        case .staged: hasBytes ? "Waiting" : "Waiting — file missing"
        case .uploading: "Uploading"
        case .uploaded: "Finishing"
        case .failed: hasBytes ? "Stopped trying" : "Stopped — file no longer here"
        case .complete: "Done"
        case .unknown(let raw): raw
        }
    }

    var sizeLabel: String {
        guard byteCount > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var attemptsLabel: String? {
        attemptCount > 0 ? (attemptCount == 1 ? "1 try" : "\(attemptCount) tries") : nil
    }
}

/// The uploads half of the sync screen: the counts, the list, and a retry that acts.
@MainActor
@Observable
final class SyncUploadsModel {

    /// Run the app's one sweep. A closure rather than the `EntrySync` itself, because that is the
    /// entire dependency — and taking the engine would mean a test had to build an `APIClient` to
    /// assert on a sentence. There is deliberately no second retry policy here: `UploadBackoff` and
    /// the row-persisted schedule are the existing machinery and this reuses them.
    private let sweep: () async -> Void
    private let context: ModelContext
    private let store: StagingStore
    let reachability: NetworkReachability

    private(set) var counts = SyncCounts()
    private(set) var rows: [SyncUploadRow] = []
    private(set) var isRetrying = false
    /// What the last press achieved. Absent until there has been one, so it reads as a result
    /// rather than a standing caption.
    private(set) var outcome: String?

    /// How long to wait for the sweep to actually move something before reporting.
    ///
    /// **A message saying nothing happened is only acceptable when it also says why**, and that
    /// requires having waited long enough to know. Injected so tests do not sleep.
    private let settleWindow: Duration

    init(
        sweep: @escaping () async -> Void,
        context: ModelContext,
        store: StagingStore = StagingStore(),
        reachability: NetworkReachability,
        settleWindow: Duration = .seconds(3)
    ) {
        self.sweep = sweep
        self.context = context
        self.store = store
        self.reachability = reachability
        self.settleWindow = settleWindow
        refresh()
    }

    var isOnline: Bool { reachability.isOnline }
    var status: SyncCounts.Status { SyncCounts.status(counts, isOnline: isOnline) }

    /// Both screens read this. One model, one set of fetches, so the Settings row and this screen
    /// cannot print two different totals.
    func refresh() {
        // **One fetch, then two views of it.** The counts and the per-file list are the same set
        // of rows read two ways, so reading the table twice was twice the work on the main actor
        // — and, worse, two chances for the number and the list to disagree between fetches while
        // a background upload delegate writes.
        let media = SyncCounts.outstandingMedia(in: context)
        counts = SyncCounts.read(outstandingMedia: media, context: context, store: store)
        rows = Self.readRows(from: media, store: store)
    }

    static func readRows(from media: [Media], store: StagingStore) -> [SyncUploadRow] {
        media
            .sorted { $0.createdAt < $1.createdAt }
            .map { row in
                SyncUploadRow(
                    id: row.id,
                    entryId: row.entryId,
                    kind: row.kind,
                    state: row.state,
                    byteCount: row.byteCount,
                    attemptCount: row.attemptCount,
                    hasBytes: SyncCounts.hasStagedBytes(row, in: store)
                )
            }
    }

    // MARK: Retry

    /// Whether the control may be shown as tappable at all.
    ///
    /// **Never show a control that cannot act.** Offline it cannot; with nothing stalled and nothing
    /// waiting there is nothing for it to do.
    var canRetry: Bool { isOnline && !counts.isClear && !isRetrying }

    /// Why it is disabled, for the row beneath it. Nil when it is enabled.
    var retryDisabledReason: String? {
        if isRetrying { return nil }
        if !isOnline { return "No connection right now. This starts working when you're back on." }
        if counts.isClear { return nil }
        return nil
    }

    /// Reset the ladder on every stalled row that can still be retried, and return how many.
    ///
    /// Rows whose staged bytes are gone are left alone: resetting one would put it back in the
    /// queue to fail again on a file that is not there, and burn the ladder doing it.
    ///
    /// `resetForManualRetry()` already existed and already does all three things this needs —
    /// attempts to zero, persisted backoff cleared, `failed` back to `staged`. It was only ever
    /// called from `TodayScreen`, never from Settings, which is the whole reason the old button
    /// could not move the rows its own copy named.
    @discardableResult
    static func prepareRetry(in context: ModelContext, store: StagingStore) -> Int {
        // Through the same one predicate as everything else, so "outstanding" cannot mean two
        // things depending on which function asked.
        let stalled = SyncCounts.outstandingMedia(in: context).filter { row in
            row.state == .failed && SyncCounts.hasStagedBytes(row, in: store)
        }
        guard !stalled.isEmpty else { return 0 }
        for row in stalled { row.resetForManualRetry() }
        try? context.save()
        return stalled.count
    }

    func retry() async {
        guard canRetry else { return }
        isRetrying = true
        outcome = nil
        defer { isRetrying = false }

        let before = counts
        let prepared = Self.prepareRetry(in: context, store: store)
        await sweep()
        refresh()

        // Bounded wait for the first actual state change, rather than reporting on the instant the
        // sweep returns — a background upload has not finished by then, and "nothing moved" would
        // be true and useless.
        if counts == before {
            let deadline = ContinuousClock.now.advanced(by: settleWindow)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                refresh()
                if counts != before { break }
            }
        }

        outcome = Self.outcome(before: before, after: counts, prepared: prepared, isOnline: isOnline)
    }

    /// A concrete outcome, always. Every branch says what happened, and where nothing happened it
    /// says why — which is the thing the old sentence "Nothing moved yet. It'll keep trying on its
    /// own." could not do, because it was reassuring about ten rows nothing would ever retry.
    static func outcome(
        before: SyncCounts,
        after: SyncCounts,
        prepared: Int,
        isOnline: Bool
    ) -> String {
        guard isOnline else {
            return "No connection right now. Nothing was sent."
        }
        if after.isClear { return "Everything's uploaded." }

        let landed = max(0, before.total - after.total)
        if landed > 0 {
            let finished = landed == 1 ? "1 finished" : "\(landed) finished"
            return "\(finished). \(after.total) still to go."
        }

        // Nothing landed inside the window. Say which of the three reasons it was.
        if prepared > 0 {
            let picked = prepared == 1 ? "1 file" : "\(prepared) files"
            return "\(picked) picked back up — still uploading."
        }
        if after.stalledWithoutBytes == after.stalledMedia, after.stalledMedia > 0 {
            let subject = after.stalledMedia == 1 ? "That file is" : "Those files are"
            return "\(subject) no longer on this phone, so there's nothing left to send."
        }
        return "Still stuck — nothing accepted the retry."
    }
}
