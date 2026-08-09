import Foundation
import SwiftData

/// Re-sends entries that were saved locally but never reached the server.
///
/// Saving is local-first: the row is in SwiftData before any request goes out, so a failure is
/// never lost work. That promise is only half-kept without this — without a sweep the entry sits
/// on the phone permanently, safe and invisible, and the parent has no way to know or fix it.
///
/// Deliberately not a general sync engine. `GET /sync` is a later phase; this only pushes local
/// writes that have not landed. Media joins it in C-5 rather than inventing a second mechanism.
@MainActor
final class EntrySync {
    private let api: APIClient
    private let context: ModelContext

    /// One sweep at a time. Two concurrent sweeps would re-POST the same rows — harmless
    /// server-side thanks to the idempotency key, but it doubles the requests and races on
    /// `syncState`.
    private var running = false

    /// Media rides the same sweep rather than getting a queue, a retry policy, and a surface
    /// of its own. Optional so the entry-only tests need no uploader.
    private let media: MediaCoordinator?

    init(api: APIClient, context: ModelContext, media: MediaCoordinator? = nil) {
        self.api = api
        self.context = context
        self.media = media
    }

    /// Everything written locally that the server has not acknowledged.
    ///
    /// `failed` is included alongside `pending` on purpose: a failure here is a network fact,
    /// not a verdict about the entry, and the next foreground is exactly when it is worth
    /// trying again.
    static func unsyncedDescriptor() -> FetchDescriptor<Entry> {
        let pending = SyncState.pending.rawValue
        let failed = SyncState.failed.rawValue
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entry.deletedAt == nil && (entry.syncState == pending || entry.syncState == failed)
            },
            // Oldest first: the archive reads better if things land in the order they happened.
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 50
        return descriptor
    }

    /// Deletions the parent made that the server has not been told about.
    ///
    /// A separate descriptor because `unsyncedDescriptor` deliberately excludes deleted rows —
    /// re-POSTing an entry the parent has just thrown away would be the worst possible outcome
    /// of a retry.
    static func pendingDeletionDescriptor() -> FetchDescriptor<Entry> {
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entry.deletedAt != nil && entry.deletionPending
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        descriptor.fetchLimit = 50
        return descriptor
    }

    /// One count for one surface. An entry still saving and a photo still uploading are the
    /// same thing to a parent: work that has not landed yet.
    func unsyncedCount() -> Int {
        let entries = (try? context.fetchCount(EntrySync.unsyncedDescriptor())) ?? 0
        let deletions = (try? context.fetchCount(EntrySync.pendingDeletionDescriptor())) ?? 0
        return entries + deletions + MediaCoordinator.outstandingCount(in: context)
    }

    /// Push what has not landed. Safe to call on every foreground; a no-op when there is
    /// nothing outstanding.
    /// **Entries drain before media, always.**
    ///
    /// Media cannot upload against an entry the server does not have — `upload-url` needs an
    /// `entry_id` it recognises. Running them in the other order, or concurrently, spends
    /// attempts on rows that cannot succeed and pushes their backoff out for no reason.
    @discardableResult
    func sweep() async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }

        let synced = await sweepEntries()
        // Deletions go after creations and before media. An entry created and deleted while
        // offline has to be created before it can be deleted — the DELETE would 404 otherwise
        // and the row would sit marked forever — and any media it had is moot once it is gone.
        await sweepDeletions()
        // Runs regardless of whether any entry was outstanding: a photo can still be in flight
        // long after its entry landed.
        await media?.sweep()
        return synced
    }

    /// Tell the server about deletions made on this phone.
    ///
    /// The row is never removed locally, only marked — deletions sync as rows with `deleted_at`
    /// set, never as absences, and that rule is the same on both sides of the wire.
    @discardableResult
    private func sweepDeletions() async -> Int {
        guard let outstanding = try? context.fetch(EntrySync.pendingDeletionDescriptor()),
              !outstanding.isEmpty
        else { return 0 }

        var pushed = 0
        for entry in outstanding {
            guard entry.existsOnServer else {
                // Never left the phone. There is nothing to delete and never was, so the flag
                // is the only thing to clear.
                entry.deletionPending = false
                pushed += 1
                continue
            }
            do {
                try await api.deleteEntry(id: entry.id)
                entry.deletionPending = false
                pushed += 1
            } catch let error as APIError where error.code == .notFound {
                // Already gone server-side — someone else's phone got there first. That is the
                // outcome this was asking for.
                entry.deletionPending = false
                pushed += 1
            } catch {
                // Offline, or a 5xx. Stays marked and is retried on the next foreground.
                continue
            }
        }
        try? context.save()
        return pushed
    }

    private func sweepEntries() async -> Int {
        guard let outstanding = try? context.fetch(EntrySync.unsyncedDescriptor()),
              !outstanding.isEmpty
        else { return 0 }

        var synced = 0
        for entry in outstanding {
            if await push(entry) { synced += 1 }
        }
        try? context.save()
        return synced
    }

    /// One entry. Returns whether it is now on the server.
    private func push(_ entry: Entry) async -> Bool {
        do {
            // An edit is a PATCH, not a second POST. Re-POSTing would present the stored
            // idempotency key and get the *original* body back — the edit would vanish and
            // the sweep would report success.
            let response = entry.existsOnServer
                ? try await api.updateEntry(entry)
                : try await api.createEntry(entry)
            entry.applyServerResponse(response)
            return true
        } catch let error as APIError {
            switch error.code {
            case .assignmentExpired:
                // The entry is still worth keeping; it just no longer completes that
                // assignment. Drop the link and let the next sweep send it as a freeform
                // entry rather than retrying a conflict forever.
                entry.assignmentId = nil
                entry.sync = .pending
            case .validationFailed, .notFound, .notAuthorized:
                // Retrying cannot fix any of these. Park it as failed so it surfaces in the
                // UI instead of looping every time the app opens.
                entry.sync = .failed
            default:
                // Offline, a 5xx, an expired session mid-sweep. All worth another attempt.
                entry.sync = .failed
            }
            return false
        } catch {
            entry.sync = .failed
            return false
        }
    }
}

extension Entry {
    /// True once the server has acknowledged this row.
    var isSynced: Bool { sync == .synced }
}
