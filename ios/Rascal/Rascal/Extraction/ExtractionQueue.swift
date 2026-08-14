import Foundation
import OSLog
import SwiftData

/// Structuring what a parent wrote, on device, once.
///
/// Shaped after `TranscriptionQueue` deliberately — same `@MainActor @Observable` form, same
/// one-at-a-time posture, same silent-degradation rule. **This is not a second background-work
/// mechanism**; it is the same one pointed at text.
///
/// ## Extract once, never re-run
///
/// Settled 2026-08-11. The alternative was tracking every `device_ai` tag a parent deleted so a
/// re-run could not resurrect it. Not re-running makes that failure *impossible* rather than
/// defended against: there is no tombstone list to get wrong, and a tag the parent removed is
/// gone for good.
///
/// The cost, stated plainly: an entry whose body is edited afterwards keeps the tags it got the
/// first time. That is the trade, and it is the safe side of it.
@MainActor
@Observable
final class ExtractionQueue {

    private static let log = Logger(subsystem: "app.rascal", category: "extraction")

    /// Why an entry was not extracted. Every case is ordinary; none is an error the parent sees.
    enum Skip: Equatable, Sendable {
        /// This phone cannot run the model. The commonest case by far.
        case unavailable
        /// **A sealed entry is never read.** See `extract(entryId:)`.
        case sealed
        /// Already done. The never-re-run rule.
        case alreadyExtracted
        /// Nothing to work from.
        case noBody
        case notFound
        case deleted
    }

    enum Outcome: Equatable, Sendable {
        case extracted(tagCount: Int)
        case skipped(Skip)
        /// The model or the write failed. The row is left exactly as it was and it will be
        /// retried on a later launch, because `extractedAt` is only stamped on success.
        case failed
    }

    private(set) var lastOutcome: Outcome?

    private let api: APIClient
    private let context: ModelContext
    private let extractor: any EntryExtracting

    /// **One extraction at a time, process-wide**, for the same reason there is one transcriber:
    /// two inference runs is twice the battery and twice the thermal load on a phone somebody is
    /// holding while parenting, and the archive is not waiting on this.
    private var running = false

    init(
        api: APIClient,
        context: ModelContext,
        extractor: any EntryExtracting = DeviceEntryExtractor()
    ) {
        self.api = api
        self.context = context
        self.extractor = extractor
    }

    var isRunning: Bool { running }

    // MARK: - The one entry point

    /// Consider one entry, opportunistically.
    ///
    /// Names a single row and never enumerates — the same rule that keeps a first launch from
    /// walking six years of archive. Genuinely deferrable work: `isDiscretionary = false` applies
    /// to uploads, not to this.
    @discardableResult
    func extract(entryId: UUID) async -> Outcome {
        guard !running else { return .skipped(.unavailable) }

        guard let entry = Self.entry(id: entryId, in: context) else {
            return record(.skipped(.notFound))
        }
        guard entry.deletedAt == nil else { return record(.skipped(.deleted)) }

        // **A sealed entry is never extracted from, and this guard runs before anything else
        // reads the body.**
        //
        // A sealed letter is written to be opened years from now. Its contents leaking into tags
        // that render on the timeline today is the highest-consequence defect available in this
        // phase — the archive would have shown the parent the thing they deliberately locked. The
        // seal is `unlockAtAge`, and the server owns it: a letter prompt applies its
        // `default_unlock_age` on create, so a row can arrive sealed without this device having
        // sent anything.
        guard entry.unlockAtAge == nil else { return record(.skipped(.sealed)) }

        // The never-re-run rule.
        guard entry.extractedAt == nil else { return record(.skipped(.alreadyExtracted)) }

        let body = (entry.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return record(.skipped(.noBody)) }

        // **Degrade silently.** A phone that cannot run the model behaves exactly as it did
        // yesterday: nothing queued, nothing written, nothing said. No retry storm — the check is
        // one call and the method returns.
        guard await extractor.availability() == .available else {
            return record(.skipped(.unavailable))
        }

        running = true
        defer { running = false }

        let details: ExtractedDetails
        do {
            details = try await extractor.extract(from: body).normalized()
        } catch {
            // Not stamped, so a later launch may try again. Nothing is surfaced.
            Self.log.debug("extraction failed for \(entryId, privacy: .public)")
            return record(.failed)
        }

        let names = details.writableTagNames
        guard !names.isEmpty else {
            // The model had nothing to say. That is a complete, successful outcome — stamp it so
            // it is not reconsidered on every launch forever.
            stamp(entry)
            return record(.extracted(tagCount: 0))
        }

        do {
            // **Only tags, and only `device_ai`.** `title` and `body` are not in this payload and
            // must never be: the parent's words are the archive and extraction adds metadata
            // beside them. The server leaves a source absent from the payload alone, so the
            // parent's own tags cannot be touched by this write.
            try await api.updateEntry(
                id: entry.id,
                changes: EntryChanges(
                    tags: .set(names.map { EntryTagWrite(name: $0, source: .deviceAI) })
                )
            )
        } catch {
            Self.log.debug("extraction write failed for \(entryId, privacy: .public)")
            return record(.failed)
        }

        stamp(entry)
        return record(.extracted(tagCount: names.count))
    }

    /// Stamped **only on success**, so a failure is retried and a success never is.
    private func stamp(_ entry: Entry) {
        entry.extractedAt = Date()
        try? context.save()
    }

    @discardableResult
    private func record(_ outcome: Outcome) -> Outcome {
        lastOutcome = outcome
        return outcome
    }

    // MARK: - Lookup

    static func entry(id: UUID, in context: ModelContext) -> Entry? {
        var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Entries this device could still extract from, for a future Settings backlog row.
    ///
    /// Deliberately **not** called anywhere automatically. Enumerating the archive on launch is
    /// the behaviour `TranscriptionQueue` was careful to avoid, and this phase does not add a
    /// backlog action of its own.
    ///
    /// **Child-scoped, and this one is not a display concern.** One store holds every child's
    /// rows. Extraction stamps `extractedAt` once and never revisits a row, so running it over
    /// the globally newest un-extracted entry can spend a sibling's only pass — and the tags it
    /// would have produced for that entry are not recoverable by reopening the app.
    static func pending(in context: ModelContext, childId: UUID) -> [Entry] {
        let child = childId
        let descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate {
                $0.childId == child && $0.deletedAt == nil && $0.extractedAt == nil
            }
        )
        return ((try? context.fetch(descriptor)) ?? []).filter {
            $0.unlockAtAge == nil && !($0.body ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
