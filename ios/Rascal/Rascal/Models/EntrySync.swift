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

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
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

    func unsyncedCount() -> Int {
        (try? context.fetchCount(EntrySync.unsyncedDescriptor())) ?? 0
    }

    /// Push what has not landed. Safe to call on every foreground; a no-op when there is
    /// nothing outstanding.
    @discardableResult
    func sweep() async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }

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
            let response = try await api.createEntry(entry)
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
