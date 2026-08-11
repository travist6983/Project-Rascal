import Foundation
import SwiftData

/// Turns what the share extension staged into entries, through the pipeline the composer uses.
///
/// **Two passes, and the split is the whole design.**
///
/// `ingest` converts the staged files and writes the `Entry` and `Media` rows. `reap` removes the
/// inbox copy, and only once the server has acknowledged the entry. In between, the ordinary sweep
/// runs: entries are pushed, then media, exactly as they are for anything the composer wrote.
/// `RootView.runSweep` calls the three in that order.
///
/// Everything here is **idempotent**, because it has to be. A drain can be interrupted at any
/// point — the app killed mid-conversion, the phone put away between entry creation and upload —
/// and the next foreground runs the whole thing again from the top. The property that makes that
/// safe is that the entry's UUID is written into the record by the extension: a second pass finds
/// the entry already in SwiftData and does nothing rather than making a second one.
///
/// **Nothing here is destructive.** Staged media is real user content that exists nowhere else
/// once Photos is closed, so a conversion that fails leaves the file where it is and tries again
/// next time. The only deletions are of files whose entry the server has confirmed, and of bytes
/// no record names.
///
/// **A class, and not a struct, for the `running` flag alone** — the same reason `EntrySync` and
/// `MediaCoordinator` are classes. See `ingest`.
@MainActor
final class ShareDrain {
    let inbox: ShareInbox
    let staging: StagingStore
    let context: ModelContext
    /// Resolved by the gate at launch and handed down. **The extension deliberately does not know
    /// which child this is for** — it has no session and no `GET /children`, and asking a parent
    /// to pick one inside a share sheet is a question a twelve-second screen cannot afford.
    /// Multi-kid selection is out of scope for this phase either way.
    let childId: UUID

    /// One ingest at a time, for the reason `EntrySync.running` and `MediaCoordinator.sweeping`
    /// exist — and here it is load-bearing rather than merely tidy.
    ///
    /// `RootView.runSweep` is called from `.task` **and** from `scenePhase == .active`, and on a
    /// cold launch both fire within a moment of each other. Converting a video suspends
    /// (`AVURLAsset.load(.isExportable)`), so a second pass can start, read the same record, see no
    /// entry for it yet — because the first pass has not inserted one — and decide to create it
    /// too.
    ///
    /// The visible damage is small, because `Entry.id` is `@Attribute(.unique)` and SwiftData
    /// upserts. **The invisible damage is not.** If the first pass's entry is pushed and marked
    /// `existsOnServer` before the second pass's insert lands, the upsert replaces it with a fresh
    /// `pending` row carrying a **new `idempotencyKey`** — and the next push therefore creates a
    /// second entry server-side rather than replaying the first. That is precisely the duplicate
    /// this phase promises cannot happen, arriving by a route the double-drain test does not take.
    /// Measured, not theorised: two concurrent ingests of one record both reported `ingested == 1`
    /// before this guard existed.
    private var running = false

    init(
        inbox: ShareInbox = .shared,
        staging: StagingStore = StagingStore(),
        context: ModelContext,
        childId: UUID
    ) {
        self.inbox = inbox
        self.staging = staging
        self.context = context
        self.childId = childId
    }

    struct Result: Equatable {
        /// Records that became a new entry on this pass.
        var ingested = 0
        /// Records whose entry was already here. The idempotency guarantee, counted rather than
        /// silent, so a double-drain is visible in a test and in the device checklist.
        var alreadyPresent = 0
        /// Media rows created and staged into the app's own store.
        var mediaStaged = 0
        /// Files the record named that could not be converted or were not there. Never fatal to
        /// the entry: the note, and every other file in the share, still land.
        var mediaSkipped = 0
        /// Inbox copies removed after the server confirmed their entry.
        var reaped = 0
        /// Records that named files and had none left, with nothing written on them. There is
        /// nothing left to recover and nothing to keep.
        var unrecoverable = 0
        /// Bytes belonging to a share that never got a record — a cancel, or an extension killed
        /// between the copy and the write.
        var orphansSwept = 0
    }

    // MARK: Ingest

    /// Everything waiting, oldest share first, turned into local rows.
    ///
    /// Runs **before** the sync sweep. `EntrySync` then pushes the entries, and only once an entry
    /// is `synced` does `MediaCoordinator.dueMedia` consider its media — which is the standing
    /// entries-before-media ordering, inherited rather than re-implemented. An extension that
    /// uploaded on its own would have had to break it.
    @discardableResult
    func ingest() async -> Result {
        var result = Result()
        guard inbox.directory != nil else { return result }
        // See `running`. A second pass while one is in flight is not extra safety, it is the
        // duplicate.
        guard !running else { return result }
        running = true
        defer { running = false }

        for record in inbox.pending() {
            if existingEntry(record.id) != nil {
                // **The double-drain guard.** The id came from the extension, so it is the same
                // one a previous pass used. Nothing is written, and `reap` decides separately
                // whether the inbox copy may go.
                result.alreadyPresent += 1
                continue
            }
            await ingest(record, into: &result)
            // The conversions below run on the main actor, the same way the composer's do. A
            // yield between records lets the run loop service a touch rather than freezing the
            // first seconds of a launch behind a twenty-photo share.
            await Task.yield()
        }
        return result
    }

    private func ingest(_ record: PendingShare, into result: inout Result) async {
        var staged: [StagedMedia] = []
        for item in record.media {
            if let one = await convert(item) {
                staged.append(one)
            } else {
                result.mediaSkipped += 1
            }
        }

        // A record that named files, has none of them left, and carries no words is not an entry
        // waiting to happen — it is a share whose bytes are gone. The same situation
        // `MediaCoordinator.beginUpload` calls unrecoverable when a staged original has vanished.
        // Creating an empty entry from it would be a lie about what the parent saved.
        if staged.isEmpty, !record.media.isEmpty, record.note == nil {
            inbox.remove(record)
            result.unrecoverable += 1
            return
        }

        let entry = Entry(
            id: record.id,
            childId: childId,
            // Freeform. A share sheet links to no assignment and no prompt — see `ShareComposer`.
            assignmentId: nil,
            occurredAt: record.occurredAt,
            // **The extension's timestamp, not now.** `created_at` is when the row was made, and
            // the row was made when the parent pressed Save in the share sheet. Re-stamping it
            // here would move it to whenever the app next happened to open, which on a phone left
            // in a pocket is hours later and is not a fact about anything.
            createdAt: record.createdAt,
            body: record.note
        )
        context.insert(entry)

        for one in staged {
            let media = Media(
                id: one.id,
                entryId: entry.id,
                kind: one.kind,
                contentType: one.contentType,
                byteCount: one.byteCount,
                stagedExtension: one.fileExtension,
                capturedAt: one.capturedAt,
                durationSeconds: one.durationSeconds
            )
            // From the conversion, not unconditionally: the staging sweep reads this flag as
            // permission to delete the only local copy of the original.
            media.hasThumbnail = one.hasThumbnail
            context.insert(media)
        }

        // **Counted only if it persisted.** A `ModelContext` that fails to save has written
        // nothing, and the next foreground re-ingests the record from scratch — which is correct,
        // and which makes a reported `ingested` on a failed save a number that contradicts the
        // store. The rest of this type is honest about what it did; this has to be too.
        do {
            try context.save()
        } catch {
            return
        }
        result.mediaStaged += staged.count
        result.ingested += 1
    }

    /// What one converted file gave us.
    private struct StagedMedia {
        let id: UUID
        let kind: String
        let contentType: String
        let byteCount: Int
        let fileExtension: String
        let capturedAt: Date?
        let durationSeconds: Int?
        let hasThumbnail: Bool
    }

    /// Convert one staged file into the app's staging store, in the archive's own formats.
    ///
    /// **The existing pipelines, not a second copy of them.** `ImagePipeline` is what makes the
    /// archive JPEG rather than HEIC and bakes orientation into the pixels; `VideoPipeline` is
    /// what makes it 1080p H.264 in MP4 and writes a poster frame. Both are decisions
    /// `docs/decisions.md` calls effectively permanent, and a share sheet that produced anything
    /// else would put two kinds of photo in one archive.
    ///
    /// Returns nil when the file is missing or unreadable. Nothing is deleted on that path — the
    /// record stays, and the next foreground tries again.
    private func convert(_ item: PendingShare.Item) async -> StagedMedia? {
        guard let source = inbox.mediaURL(for: item),
              FileManager.default.fileExists(atPath: source.path)
        else { return nil }

        switch item.kind {
        case .photo:
            guard let processed = try? ImagePipeline.process(fileAt: source),
                  (try? staging.stage(data: processed.data, as: item.id, ext: processed.fileExtension)) != nil,
                  (try? staging.stageThumbnail(processed.thumbnail, for: item.id)) != nil
            else { return nil }

            return StagedMedia(
                id: item.id,
                kind: item.kind.mediaKind,
                contentType: processed.contentType,
                byteCount: processed.data.count,
                fileExtension: processed.fileExtension,
                // The record's date wins where it has one: it is what the parent was shown and
                // what the entry was filed under, and the two disagreeing would put a different
                // date on the entry than on its own photo.
                capturedAt: item.capturedAt ?? processed.capturedAt,
                durationSeconds: nil,
                hasThumbnail: true
            )

        case .video:
            guard let processed = try? await VideoPipeline.process(
                fileAt: source, into: staging, as: item.id
            ) else { return nil }

            var hasThumbnail = false
            if let poster = processed.posterFrame {
                // Propagated the way `MediaDraftBuilder.makeVideo` propagates it: a poster that
                // exists and cannot be written leaves the row claiming a thumbnail it does not
                // have, and the staging sweep reads that claim as permission to delete the only
                // local copy of the file.
                hasThumbnail = (try? staging.stageThumbnail(poster, for: item.id)) != nil
                if !hasThumbnail { return nil }
            }

            return StagedMedia(
                id: item.id,
                kind: item.kind.mediaKind,
                contentType: processed.contentType,
                byteCount: processed.byteCount,
                fileExtension: processed.fileExtension,
                capturedAt: item.capturedAt ?? processed.capturedAt,
                durationSeconds: processed.durationSeconds,
                hasThumbnail: hasThumbnail
            )
        }
    }

    // MARK: Reap

    /// Remove the inbox copy of everything the server now holds.
    ///
    /// **Runs after the sweep, never before it.** The rule is that staged files go only once the
    /// entry is confirmed created server-side, and `existsOnServer` is the flag that says so — it
    /// is set by `Entry.applyServerResponse` and by nothing else. Removing on ingest would mean a
    /// failed `POST /entries` had already thrown away the only copy of the photo.
    ///
    /// A deleted entry reaps too. If the parent has thrown the entry away there is nothing for the
    /// inbox copy to become, whether or not the server ever heard of it — and without this the
    /// record would sit in the container forever, retried on every launch against an entry that
    /// exists precisely so it can be gone.
    @discardableResult
    func reap() -> Result {
        var result = Result()
        guard inbox.directory != nil else { return result }

        for record in inbox.pending() {
            guard let entry = existingEntry(record.id) else { continue }
            guard entry.existsOnServer || entry.deletedAt != nil else { continue }
            inbox.remove(record)
            result.reaped += 1
        }

        result.orphansSwept = inbox.sweepOrphans()
        return result
    }

    // MARK: Internals

    /// Whether this share has already become an entry.
    ///
    /// Deliberately does **not** filter `deleted_at`. A share drained and then deleted must not be
    /// drained a second time — soft deletes are how this app deletes, and a row with `deleted_at`
    /// set is still a row that exists.
    private func existingEntry(_ id: UUID) -> Entry? {
        var descriptor = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
