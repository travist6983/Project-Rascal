import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Staging, and the reconciliation between a filesystem and a database that will drift.
///
/// Every test runs against a temporary directory, never the app's real staging root.
@MainActor
@Suite("Staging")
struct StagingStoreTests {

    private func makeStore() -> StagingStore {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "rascal-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        return StagingStore(root: root)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([Entry.self, Media.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: Staging

    @Test("a picked file is copied in, and the source is left alone")
    func copiesRatherThanMoves() throws {
        let store = makeStore()
        let source = URL(filePath: NSTemporaryDirectory()).appending(path: "src-\(UUID()).jpg")
        try Data("bytes".utf8).write(to: source)

        let id = UUID()
        let staged = try store.stage(contentsOf: source, as: id)

        #expect(store.exists(staged))
        #expect(try Data(contentsOf: staged) == Data("bytes".utf8))
        // The picker may still own the original; moving it out from under PhotoKit is not ours.
        #expect(store.exists(source), "the source must survive — it is not ours to move")
    }

    @Test("the staged path is derivable from the id and extension alone")
    func pathIsReconstructable() throws {
        let store = makeStore()
        let id = UUID()
        let staged = try store.stage(data: Data("x".utf8), as: id, ext: "jpg")

        // This is what makes a force quit survivable: nothing needs to have been remembered.
        #expect(store.originalURL(for: id, ext: "jpg") == staged)
        #expect(staged.lastPathComponent == "\(id.uuidString.lowercased()).jpg")
    }

    @Test("re-staging the same id overwrites cleanly")
    func restagingOverwrites() throws {
        let store = makeStore()
        let id = UUID()
        _ = try store.stage(data: Data("first".utf8), as: id, ext: "jpg")
        let second = try store.stage(data: Data("second".utf8), as: id, ext: "jpg")
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test("a missing or odd extension still yields a usable path")
    func toleratesOddExtensions() throws {
        let store = makeStore()
        let id = UUID()
        #expect(store.originalURL(for: id, ext: "").pathExtension == "dat")
        #expect(store.originalURL(for: id, ext: ".JPG").pathExtension == "jpg")
    }

    @Test("thumbnails and originals are distinguishable and map back to their media id")
    func namingRoundTrips() throws {
        let store = makeStore()
        let id = UUID()
        let original = try store.stage(data: Data("o".utf8), as: id, ext: "jpg")
        let thumb = try store.stageThumbnail(Data("t".utf8), for: id)

        #expect(store.mediaId(of: original) == id)
        #expect(store.mediaId(of: thumb) == id)
        #expect(store.isThumbnail(thumb))
        #expect(!store.isThumbnail(original))
    }

    // MARK: The sweep rule

    @Test("an uploaded original is kept until a thumbnail exists")
    func keepsOriginalUntilThumbnailed() throws {
        let store = makeStore()
        let context = try makeContext()
        let (_, media) = try seed(context: context, store: store, state: .complete, thumbnail: false)

        StagingSweeper(store: store, context: context).sweep()

        // Deleting on `complete` alone makes the first timeline render refetch everything.
        #expect(store.exists(store.originalURL(for: media.id, ext: "jpg")))
        #expect(media.stagedExtension == "jpg")
    }

    @Test("an uploaded, thumbnailed original is disposed")
    func disposesWhenBothConditionsHold() throws {
        let store = makeStore()
        let context = try makeContext()
        let (_, media) = try seed(context: context, store: store, state: .complete, thumbnail: true)

        let result = StagingSweeper(store: store, context: context).sweep()

        #expect(result.disposedOriginals == 1)
        #expect(!store.exists(store.originalURL(for: media.id, ext: "jpg")))
        #expect(media.stagedExtension == nil)
        // The thumbnail stays: it is what renders in the original's place.
        #expect(store.exists(store.thumbnailURL(for: media.id)))
    }

    @Test("an unfinished upload is never disposed, thumbnail or not")
    func neverDisposesUnfinished() throws {
        let store = makeStore()
        let context = try makeContext()
        let (_, media) = try seed(context: context, store: store, state: .uploading, thumbnail: true)

        StagingSweeper(store: store, context: context).sweep()

        // This file is the only copy of the photo until the server acknowledges it.
        #expect(store.exists(store.originalURL(for: media.id, ext: "jpg")))
    }

    // MARK: Drift

    @Test("a file with no media row is an orphan and is removed once it is old enough")
    func removesOrphanFiles() throws {
        let store = makeStore()
        let context = try makeContext()
        // A crash between writing bytes and saving the row leaves exactly this.
        _ = try store.stage(data: Data("orphan".utf8), as: UUID(), ext: "jpg")

        // A day and a minute later. The file is written now, so the clock moves rather than the
        // file's timestamp — back-dating a file is the one thing this rule must not depend on.
        let later = Date().addingTimeInterval(StagingSweeper.orphanGrace + 60)
        let result = StagingSweeper(store: store, context: context).sweep(now: later)

        #expect(result.orphanFiles == 1)
        #expect(store.stagedFiles().isEmpty)
    }

    @Test("a just-written file with no media row is a recording in hand, not debris")
    func keepsYoungOrphans() throws {
        // **The take-deleting bug.** A recording is staged the moment it stops and gets no `Media`
        // row until the composer saves. Locking the screen mid-recording is a background then a
        // foreground, and the foreground runs this sweep — so the unqualified orphan rule deleted
        // the file on the way back to the review screen, and the parent found a scrubber pointing
        // at nothing.
        let store = makeStore()
        let context = try makeContext()
        let staged = try store.stage(data: Data("a take".utf8), as: UUID(), ext: "m4a")

        let result = StagingSweeper(store: store, context: context).sweep()

        #expect(result.youngOrphansKept == 1)
        #expect(result.orphanFiles == 0)
        #expect(store.exists(staged), "the recording is still there to be saved")
    }

    @Test("the grace window protects photos and video too, not only audio")
    func youngOrphanRuleIsNotAudioOnly() throws {
        // The composer stages every kind before saving, so a fix scoped to m4a would leave a
        // picked photo being deleted out from under the same screen.
        let store = makeStore()
        let context = try makeContext()
        let photo = try store.stage(data: Data("photo".utf8), as: UUID(), ext: "jpg")
        let video = try store.stage(data: Data("video".utf8), as: UUID(), ext: "mov")

        let result = StagingSweeper(store: store, context: context).sweep()

        #expect(result.youngOrphansKept == 2)
        #expect(store.exists(photo))
        #expect(store.exists(video))
    }

    @Test("an unrecognised filename is left alone rather than guessed at")
    func leavesForeignFilesAlone() throws {
        let store = makeStore()
        let context = try makeContext()
        let foreign = store.root.appending(path: "not-ours.txt")
        try Data("?".utf8).write(to: foreign)

        let result = StagingSweeper(store: store, context: context).sweep()

        #expect(result.orphanFiles == 0)
        #expect(store.exists(foreign), "guessing at an unrecognised filename is how real data dies")
    }

    @Test("media belonging to a deleted entry goes with it")
    func removesFilesOfDeletedEntries() throws {
        let store = makeStore()
        let context = try makeContext()
        let (entry, media) = try seed(context: context, store: store, state: .staged, thumbnail: true)
        entry.deletedAt = Date()

        let result = StagingSweeper(store: store, context: context).sweep()

        #expect(result.deletedEntryFiles == 2, "original and thumbnail both")
        #expect(!store.exists(store.originalURL(for: media.id, ext: "jpg")))
        #expect(!store.exists(store.thumbnailURL(for: media.id)))
    }

    @Test("a complete row with no local copy is flagged for refetch, not lost")
    func flagsRefetchRatherThanLosing() throws {
        let store = makeStore()
        let context = try makeContext()
        let (_, media) = try seed(context: context, store: store, state: .complete, thumbnail: false)
        // Simulate a restored container: the row survived, the files did not.
        store.removeAll(for: media.id)
        media.hasThumbnail = false

        let result = StagingSweeper(store: store, context: context).sweep()

        // The bytes are in storage. `presign_get` can fetch them, so this is a cache miss.
        #expect(result.flaggedForRefetch == 1)
        #expect(StagingSweeper.needingRefetch(context: context, store: store).count == 1)
    }

    // MARK: Helpers

    private func seed(
        context: ModelContext,
        store: StagingStore,
        state: MediaUploadState,
        thumbnail: Bool
    ) throws -> (Entry, Media) {
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "with a photo")
        context.insert(entry)

        let media = Media(
            entryId: entry.id,
            kind: "photo",
            contentType: "image/jpeg",
            byteCount: 5,
            stagedExtension: "jpg"
        )
        media.state = state
        media.hasThumbnail = thumbnail
        context.insert(media)

        _ = try store.stage(data: Data("photo".utf8), as: media.id, ext: "jpg")
        if thumbnail { _ = try store.stageThumbnail(Data("thumb".utf8), for: media.id) }
        return (entry, media)
    }
}
