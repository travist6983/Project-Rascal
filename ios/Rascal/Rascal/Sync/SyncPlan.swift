import Foundation

/// What a pull *would* do, computed without doing any of it.
///
/// The dry run is the only way to look at this engine before trusting it with an archive, so the
/// plan is a first-class value rather than a log line. The same type is produced whether or not
/// the changes are applied: `SyncEngine.plan` builds it, `SyncEngine.apply` consumes it. That is
/// deliberate — a dry run that ran different code from the real thing would be a report about a
/// program nobody is going to run.

// MARK: - Vocabulary

nonisolated enum SyncEntity: String, Sendable, CaseIterable {
    case entry, media, assignment, tag

    /// "3 entries", "1 entry".
    func counted(_ n: Int) -> String {
        n == 1 ? "1 \(rawValue)" : "\(n) \(rawValue)s"
    }

    var plural: String { "\(rawValue)s" }
}

nonisolated enum SyncAction: String, Sendable, CaseIterable {
    /// A record this device has never held.
    case insert
    /// A record this device holds at an older version.
    case update
    /// The server says deleted and this device does not. **Soft only** — the row stays.
    case softDelete
    /// A local record with unpushed changes. The push queue wins; the pull leaves it alone.
    case skippedLocalPending
    /// Already held at this version or newer. The overlap window guarantees these exist.
    case unchanged

    var label: String {
        switch self {
        case .insert: "insert"
        case .update: "update"
        case .softDelete: "soft-delete"
        case .skippedLocalPending: "skipped (local pending)"
        case .unchanged: "unchanged"
        }
    }

    /// Which verdict survives when one record is decided twice in one run.
    ///
    /// The overlap window guarantees round two re-reads records round one already applied, and by
    /// then they *are* unchanged — round two is looking at round one's own work. Letting the later
    /// verdict win would make the report say "0 soft-deletes" immediately after soft-deleting
    /// something, which is precisely the undercount that makes a report untrustworthy.
    ///
    /// So the most significant thing that happened to the record wins, not the last thing said
    /// about it. Deletion outranks everything because it is the one action a reader checks
    /// one by one.
    var significance: Int {
        switch self {
        case .softDelete: 4
        case .insert: 3
        case .update: 2
        case .skippedLocalPending: 1
        case .unchanged: 0
        }
    }
}

// MARK: - One decision

nonisolated struct PlannedChange: Sendable, Identifiable {
    let entity: SyncEntity
    /// The record's id. For a tag link this is the **entry** id, because a link has no id of its
    /// own that means anything to a reader.
    let recordId: UUID
    let action: SyncAction
    /// Something a human can recognise: an entry's title or the first words of its body, a
    /// media row's kind, an assignment's prompt, a tag's name.
    let preview: String
    /// **When it happened**, for entries. Never `created_at` and never `updated_at` — the two
    /// are different fields doing different jobs, and a deletion list sorted by the wrong one
    /// reads as a different archive.
    let occurredAt: Date?
    /// What makes this record distinct beyond its id.
    ///
    /// Only tags need it, and they need it badly: a tag link is keyed on `recordId` = the entry
    /// id, so six tags on one entry would collapse into one planned change without the tag name
    /// here. Nil everywhere else, where the id already identifies the record.
    let discriminator: String?

    init(
        entity: SyncEntity,
        recordId: UUID,
        action: SyncAction,
        preview: String,
        occurredAt: Date?,
        discriminator: String? = nil
    ) {
        self.entity = entity
        self.recordId = recordId
        self.action = action
        self.preview = preview
        self.occurredAt = occurredAt
        self.discriminator = discriminator
    }

    /// Identity across rounds of one run. Deliberately excludes `action`: the point is to notice
    /// that round two is talking about the record round one already decided on, *especially*
    /// when it reached a different decision.
    var dedupeKey: String {
        "\(entity.rawValue):\(recordId.uuidString):\(discriminator ?? "")"
    }

    var id: String { "\(dedupeKey):\(action.rawValue)" }
}

/// A record where local and server disagreed, and who won.
nonisolated struct SyncConflict: Sendable, Identifiable {
    enum Winner: String, Sendable {
        /// The local row had unpushed changes. The push queue wins and reconciles on the next
        /// pull after a successful push.
        case local
        /// Last-write-wins by `updated_at`, matching the server's documented behaviour.
        case server
    }

    let entity: SyncEntity
    let recordId: UUID
    let winner: Winner
    let preview: String
    /// Why, in one clause. Read out loud in the report.
    let reason: String

    var id: String { "\(entity.rawValue):\(recordId.uuidString)" }
}

/// Something the client did not understand.
///
/// **Loud on purpose.** Reading "12 records I did not understand" is a far better outcome than
/// having twelve records quietly dropped, so nothing in the apply path swallows one of these.
nonisolated struct SyncAnomaly: Sendable, Identifiable {
    enum Kind: String, Sendable {
        /// A key in the response body this client does not model.
        case unknownResponseKey
        /// The same id twice in one batch. The later one wins; both are named.
        case duplicateIdInBatch
        /// A media row whose entry is neither in this batch nor already on this device.
        case mediaWithoutEntry
        /// A tag link pointing at an entry this device has never seen.
        case tagWithoutEntry
        /// A constrained value the client has no case for — a new `status`, a new `kind`.
        case unrecognisedValue
        /// The paging loop hit its cap with the cursor still moving.
        case pagingCapReached

        var label: String {
            switch self {
            case .unknownResponseKey: "unknown key in the response"
            case .duplicateIdInBatch: "the same id twice in one batch"
            case .mediaWithoutEntry: "media whose entry is unknown"
            case .tagWithoutEntry: "a tag on an unknown entry"
            case .unrecognisedValue: "a value this client has no case for"
            case .pagingCapReached: "the paging cap was reached"
            }
        }
    }

    let kind: Kind
    let detail: String

    var id: String { "\(kind.rawValue):\(detail)" }
}

// MARK: - The plan

nonisolated struct SyncPlan: Sendable {
    /// The cursor the pull started from. Nil means a full pull from zero.
    var cursorBefore: Date?
    /// Where the cursor would land. Nil when nothing was fetched at all.
    var cursorAfter: Date?
    /// How many `GET /sync` calls it took. Two is the normal number — see `SyncEngine`.
    var rounds: Int = 0
    /// Records the server sent, across every round.
    var fetched: Int = 0
    /// Records that arrived in more than one round of this run.
    ///
    /// This is the overlap window measured directly: the server lags the cursor behind the newest
    /// row it saw, so the next round deliberately re-reads that band. On a bulk-imported archive,
    /// where every row shares almost the same `updated_at`, this can equal the whole archive —
    /// which is the window working, and the reason every apply path has to be idempotent rather
    /// than merely duplicate-tolerant.
    var reDeliveredAcrossRounds: Int = 0

    var changes: [PlannedChange] = []
    var conflicts: [SyncConflict] = []
    var anomalies: [SyncAnomaly] = []

    /// True when this plan was produced by a dry run and nothing was written.
    var isDryRun: Bool = false

    // MARK: Settling it

    /// Collapse what the overlap window said twice.
    ///
    /// `changes` is already deduplicated as it is built, because the winning verdict depends on
    /// significance rather than order. Conflicts and anomalies are plain repeats — the same
    /// record skipped in both rounds is one conflict, not two — so the first mention of each is
    /// kept and the rest dropped. Called once per run, before the plan is handed to anyone.
    mutating func collapseRepeats() {
        var seenConflicts = Set<String>()
        conflicts = conflicts.filter { seenConflicts.insert($0.id).inserted }
        var seenAnomalies = Set<String>()
        anomalies = anomalies.filter { seenAnomalies.insert($0.id).inserted }
    }

    // MARK: Reading it

    func changes(_ entity: SyncEntity, _ action: SyncAction) -> [PlannedChange] {
        changes.filter { $0.entity == entity && $0.action == action }
    }

    func count(_ entity: SyncEntity, _ action: SyncAction) -> Int {
        changes.reduce(0) { $0 + (($1.entity == entity && $1.action == action) ? 1 : 0) }
    }

    func count(_ action: SyncAction) -> Int {
        changes.reduce(0) { $0 + ($1.action == action ? 1 : 0) }
    }

    /// Everything that would leave the archive, across every entity. The list the parent reads
    /// one by one before enabling anything.
    var deletions: [PlannedChange] {
        changes.filter { $0.action == .softDelete }
            .sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
    }

    /// Records already held at this version or newer.
    ///
    /// The other half of the overlap window's footprint, seen from the store rather than from the
    /// wire: records the server re-sent that this device had already applied. `reDeliveredAcross
    /// Rounds` counts the same phenomenon within one run; this counts it across runs too.
    var alreadyHeld: Int { count(.unchanged) }

    /// Would this pull touch the store at all?
    var isNoOp: Bool {
        count(.insert) == 0 && count(.update) == 0 && count(.softDelete) == 0
    }

    var writeCount: Int {
        count(.insert) + count(.update) + count(.softDelete)
    }

    // MARK: The report

    /// Plain text, sized for reading on a phone and pasting back into a conversation.
    ///
    /// Deliberately not JSON and deliberately not a table of raw ids. The question it has to
    /// answer is "would I let this run against my archive", and that is answered by prose and by
    /// the deletion list, not by a dump.
    func report(now: Date = Date()) -> String {
        var lines: [String] = []

        lines.append(isDryRun ? "SYNC DRY RUN — nothing was written" : "SYNC PULL — applied")
        lines.append(Self.stamp(now))
        lines.append("")

        lines.append(contentsOf: cursorBlock())
        lines.append("")
        lines.append(contentsOf: countsBlock())

        if !deletions.isEmpty {
            lines.append("")
            lines.append(contentsOf: deletionBlock())
        }

        if !conflicts.isEmpty {
            lines.append("")
            lines.append(contentsOf: conflictBlock())
        }

        lines.append("")
        lines.append(contentsOf: anomalyBlock())

        return lines.joined(separator: "\n")
    }

    private func cursorBlock() -> [String] {
        [
            "POSITION",
            "  from      \(cursorBefore.map(Self.stamp) ?? "nothing stored — a full pull from zero")",
            "  to        \(cursorAfter.map(Self.stamp) ?? "unchanged — nothing was fetched")",
            "  rounds    \(rounds) · \(fetched) record\(fetched == 1 ? "" : "s") received",
            "",
            "  THE OVERLAP WINDOW (\(Int(SyncEngine.overlapWindow))s)",
            "  The server hands back max(updated_at) minus \(Int(SyncEngine.overlapWindow))s, so rows written by a",
            "  slow transaction are re-delivered rather than skipped. Both numbers",
            "  below being non-zero is the window working, not a fault.",
            "    re-sent this run    \(reDeliveredAcrossRounds) arrived in more than one round",
            "    already applied     \(alreadyHeld) were held at this version or newer",
        ]
    }

    private func countsBlock() -> [String] {
        var lines = ["WHAT WOULD CHANGE"]
        if changes.isEmpty {
            lines.append("  nothing — the server had no records this device has not already applied")
            return lines
        }

        // Column headings, then one row per entity that appears at all. An entity with no
        // records is omitted rather than shown as five zeroes.
        lines.append("             insert  update  delete   skip  same")
        for entity in SyncEntity.allCases {
            let row = SyncAction.allCases.map { count(entity, $0) }
            guard row.contains(where: { $0 > 0 }) else { continue }
            let name = entity.plural.padding(toLength: 12, withPad: " ", startingAt: 0)
            let cells = row.map { String($0).leftPadded(to: 6) }.joined(separator: "  ")
            lines.append("  \(name)\(cells)")
        }
        lines.append("")
        lines.append("  \(writeCount) write\(writeCount == 1 ? "" : "s") in total"
            + (isNoOp ? " — this pull is a no-op" : ""))
        return lines
    }

    /// Every deletion, in full, never summarised.
    ///
    /// Deletions are the only action here that feels irreversible, and the brief for this report
    /// was explicit: an undercount is worse than an unfinished feature. So the list is complete
    /// and it is not truncated, however long it gets.
    private func deletionBlock() -> [String] {
        var lines = ["WOULD BE SOFT-DELETED — \(deletions.count) record\(deletions.count == 1 ? "" : "s")"]
        lines.append("  (the row stays in the local store with deleted_at set; nothing is removed)")
        for change in deletions {
            let when = change.occurredAt.map(Self.day) ?? "no occurred_at"
            lines.append("  · [\(change.entity.rawValue)] \(when) — \(change.preview)")
            lines.append("      \(change.recordId.uuidString)")
        }
        return lines
    }

    private func conflictBlock() -> [String] {
        var lines = ["CONFLICTS RESOLVED — \(conflicts.count)"]
        for conflict in conflicts {
            lines.append("  · [\(conflict.entity.rawValue)] \(conflict.winner.rawValue) won — \(conflict.preview)")
            lines.append("      \(conflict.reason)")
            lines.append("      \(conflict.recordId.uuidString)")
        }
        return lines
    }

    private func anomalyBlock() -> [String] {
        guard !anomalies.isEmpty else {
            return ["ANOMALIES", "  none — every record was understood"]
        }
        var lines = ["ANOMALIES — \(anomalies.count). Read these."]
        // Grouped, because twenty of the same kind is one fact, not twenty.
        for kind in Self.anomalyOrder {
            let matching = anomalies.filter { $0.kind == kind }
            guard !matching.isEmpty else { continue }
            lines.append("  \(kind.label) — \(matching.count)")
            for anomaly in matching {
                lines.append("    · \(anomaly.detail)")
            }
        }
        return lines
    }

    private static let anomalyOrder: [SyncAnomaly.Kind] = [
        .unknownResponseKey, .duplicateIdInBatch, .mediaWithoutEntry,
        .tagWithoutEntry, .unrecognisedValue, .pagingCapReached,
    ]

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Formatting helpers for the report. `nonisolated` because the report is built off the
/// main actor as readily as on it, and this module defaults to main-actor isolation.
nonisolated extension String {
    /// Right-aligned in a fixed column, so the counts table lines up in a monospaced view.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    /// The first few words of an entry, for a line a parent can recognise a record by.
    ///
    /// Whitespace is collapsed first: a body with a newline in it would otherwise break the
    /// report's line structure and make the deletion list unreadable exactly when it matters.
    func previewLine(limit: Int = 60) -> String {
        let flat = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
