import Foundation
import SwiftData

/// Folds server entries into the local cache, and marks local deletions.
///
/// The rule, and it is the same one the Today board follows: **the server is the source of
/// truth for everything except what the parent just did.** A row this phone has written and not
/// yet pushed is newer than anything the server can say about it, so a reconcile leaves it
/// alone until the sweep has landed it. Overwriting it would mean an edit made on a train
/// disappears the moment the train reaches a signal.
///
/// Identity is the client-generated entry id, so a composer-created row and the same row coming
/// back from `GET /entries` are one row and never two.
@MainActor
enum EntryCache {

    /// Fold a page of server entries into SwiftData. Returns how many rows were new.
    @discardableResult
    static func upsert(_ responses: [EntryResponse], into context: ModelContext) -> Int {
        var created = 0
        for response in responses {
            if upsert(response, into: context) { created += 1 }
        }
        try? context.save()
        return created
    }

    /// One entry. Returns whether the row had to be created.
    @discardableResult
    static func upsert(_ response: EntryResponse, into context: ModelContext) -> Bool {
        guard let existing = entry(id: response.id, in: context) else {
            let entry = Entry(
                id: response.id,
                childId: response.childId,
                assignmentId: response.assignmentId,
                occurredAt: response.occurredAt,
                createdAt: response.createdAt,
                title: response.title,
                body: response.body,
                unlockAtAge: response.unlockAtAge
            )
            entry.applyServerTruth(response)
            context.insert(entry)
            upsertMedia(response.media, entryId: response.id, into: context)
            return true
        }

        // A local write the server has not acknowledged yet — a save made offline, an edit
        // queued for the next sweep, a deletion on its way. All of them are the parent's most
        // recent intent, and none of them may be overwritten by an older server row.
        if existing.sync == .synced, !existing.deletionPending {
            existing.applyServerTruth(response)
        }
        upsertMedia(response.media, entryId: response.id, into: context)
        return false
    }

    /// Media summaries onto local rows.
    ///
    /// Only rows the server calls `complete` are cached. One that is still uploading has no
    /// bytes this device can reach, and creating it here would enrol it in the upload sweep —
    /// which would hunt for a staged file that was never on this phone and mark somebody
    /// else's healthy upload as failed.
    static func upsertMedia(
        _ summaries: [MediaSummaryResponse],
        entryId: UUID,
        into context: ModelContext
    ) {
        for summary in summaries {
            if let existing = media(id: summary.id, in: context) {
                existing.applyServerSummary(summary)
            } else if let created = Media.fromServer(summary, entryId: entryId) {
                context.insert(created)
            }
        }
    }

    // MARK: Deleting

    /// Mark an entry deleted on this phone. The request is the sweep's job, not this one's.
    ///
    /// Soft only. The row stays with `deleted_at` set — a hard delete would make the deletion
    /// unsyncable, because a client cannot infer one from a missing record.
    static func markDeleted(_ entry: Entry, in context: ModelContext, now: Date = Date()) {
        guard entry.deletedAt == nil else { return }
        entry.deletedAt = now
        entry.deletionPending = true
        entry.updatedAt = now

        // The media has to carry its own `deleted_at`, exactly as the server does it — a client
        // that keeps the media row alive keeps rendering the photo. Marking them also releases
        // their staged files to the next staging sweep.
        for row in media(ofEntry: entry.id, in: context) where row.deletedAt == nil {
            row.deletedAt = now
        }
        try? context.save()
    }

    // MARK: Lookups

    static func entry(id: UUID, in context: ModelContext) -> Entry? {
        var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func media(id: UUID, in context: ModelContext) -> Media? {
        var descriptor = FetchDescriptor<Media>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Live media for one entry, oldest first — the order they were attached, which is the
    /// order a multi-photo card should show them in.
    static func media(ofEntry entryId: UUID, in context: ModelContext) -> [Media] {
        let descriptor = FetchDescriptor<Media>(
            predicate: #Predicate { $0.entryId == entryId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
