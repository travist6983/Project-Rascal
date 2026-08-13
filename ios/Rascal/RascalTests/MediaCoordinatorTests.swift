import Foundation
import SwiftData
import Testing

@testable import Rascal

// MARK: - Server shapes
//
// Free functions rather than methods on the suite, for the reason `SyncFixtures` states: the stub
// performer's closures are `@Sendable` and cannot reach a helper isolated to the suite.

/// A multipart `UploadTicket`: `parts` and `chunk_bytes` instead of a single `upload_url`, which
/// is the branch `beginUpload` chooses on.
private func multipartTicketJSON(
    mediaId: UUID,
    s3Key: String,
    parts: [(number: Int, url: String)],
    chunkBytes: Int
) -> Data {
    let partsJSON = "[" + parts
        .map { #"{"part_number":\#($0.number),"upload_url":"\#($0.url)"}"# }
        .joined(separator: ",") + "]"
    return Data("""
    {"media_id":"\(mediaId.uuidString)","s3_key":"\(s3Key)","upload_url":null,
     "parts":\(partsJSON),"multipart":true,
     "chunk_bytes":\(chunkBytes),"expires_in":3600}
    """.utf8)
}

/// The one error envelope the server renders, from `docs/api-contract.md`.
private func mediaErrorJSON(_ code: String, _ message: String) -> Data {
    Data(#"{"error":{"code":"\#(code)","message":"\#(message)","field":null}}"#.utf8)
}

/// The two legs `MediaCoordinator` owns: asking the server where to put a file, and telling it the
/// file landed.
///
/// The type's doc comments make two promises the archive depends on, and neither was under test
/// before this file existed:
///
/// 1. *"a PUT that succeeded while `complete` failed must not re-upload"* — a failed
///    acknowledgement stays `uploaded` and spends its attempt on the handshake, never on the bytes.
/// 2. *"A part is still outstanding. Completing now would assemble a truncated object"* — storage
///    accepts a short assembly and reports success, and nobody notices until the video will not
///    play.
///
/// ## Two things here are not the usual harness, and both are forced
///
/// **The store is `LocalStore.shared`, not an in-memory container.** `beginUpload` and
/// `finishUpload` build `ModelContext(LocalStore.shared)` themselves — deliberately, because a
/// background upload delegate can call into them in a process where nothing has been restored and
/// there is no container to hand over. There is no seam to inject one, so a row these tests want
/// the coordinator to find has to live where it will look. Every row is addressed by a fresh UUID
/// and deleted again in a `defer`, the suite is `.serialized` so two tests never share the store at
/// once, and no assertion depends on any row but its own — so a simulator someone has actually used
/// the app on is neither disturbed nor able to disturb this.
///
/// **No test lets the coordinator reach `MediaUploader.shared`.** That singleton claims a
/// process-wide *background* session; handing it a file from a unit test starts a real transfer
/// whose delegate writes back into this same store long after the test that caused it has finished.
/// Every case below stops short of the dispatch, and the one that plans multipart parts says how in
/// its own comment.
@MainActor
@Suite("Media coordinator", .serialized)
struct MediaCoordinatorTests {

    // MARK: - Fixtures

    /// A context over the store the coordinator will actually look in.
    private func storeContext() -> ModelContext { ModelContext(LocalStore.shared) }

    /// One entry and one media row hanging off it.
    ///
    /// The entry is not decoration: `POST /media/upload-url` carries `entry_id`, and a media row
    /// belonging to no entry is a state the app cannot produce.
    ///
    /// **It is left `pending` on purpose.** The unit test host is a real app, and on a simulator
    /// someone has signed in on it renders `RootView` and runs a sweep at launch. `dueMedia`
    /// excludes media whose entry has not synced, so an un-synced entry is what guarantees that
    /// sweep cannot pick up a row this suite is mid-assertion on. Neither `beginUpload` nor
    /// `finishUpload` reads the entry's sync state — only the sweep does — so nothing under test
    /// is changed by it.
    private func seed(
        kind: String = "photo",
        contentType: String = "image/jpeg",
        bytes: Int = 120_000,
        state: MediaUploadState = .staged,
        stagedExtension: String? = "jpg",
        chunkBytes: Int? = nil,
        attempts: Int = 0
    ) throws -> (entryId: UUID, mediaId: UUID) {
        let context = storeContext()

        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "with a file")
        entry.sync = .pending
        context.insert(entry)

        let media = Media(
            entryId: entry.id,
            kind: kind,
            contentType: contentType,
            byteCount: bytes,
            stagedExtension: stagedExtension
        )
        media.chunkBytes = chunkBytes
        media.attemptCount = attempts
        media.state = state
        context.insert(media)

        try context.save()
        return (entry.id, media.id)
    }

    /// Read the row back through a context the coordinator never used, which is the only way to see
    /// what it persisted rather than what it happened to leave in memory.
    private func read(_ mediaId: UUID) -> Media? {
        var descriptor = FetchDescriptor<Media>(predicate: #Predicate { $0.id == mediaId })
        descriptor.fetchLimit = 1
        return (try? storeContext().fetch(descriptor))?.first
    }

    /// Delete everything a test created. This store outlives the process, so a test that leaves
    /// rows behind changes what the next run — and the next launch of the app on this simulator —
    /// sees.
    private func purge(entryId: UUID, mediaId: UUID) {
        let context = storeContext()
        for part in MediaUploader.parts(of: mediaId, in: context) { context.delete(part) }
        for row in (try? context.fetch(
            FetchDescriptor<Media>(predicate: #Predicate { $0.id == mediaId })
        )) ?? [] {
            context.delete(row)
        }
        for row in (try? context.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { $0.id == entryId })
        )) ?? [] {
            context.delete(row)
        }
        try? context.save()
    }

    // MARK: - beginUpload

    /// The bytes are gone and were never sent. Nothing can recover this, and a row left retrying
    /// against a file that does not exist would spend six attempts learning that.
    @Test("a staged row whose file has vanished is failed rather than retried")
    func aMissingStagedFileIsTerminal() async throws {
        let (entryId, mediaId) = try seed()
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let performer = StubPerformer()
        // A fresh staging root: nothing was ever written for this id.
        let coordinator = MediaCoordinator(api: testClient(performer), store: temporaryStagingStore())

        await coordinator.beginUpload(mediaId: mediaId)

        let row = try #require(read(mediaId))
        #expect(row.state == .failed)
        #expect(row.attemptCount == 0, "no attempt was made, so none should be recorded")
        #expect(performer.count(for: "upload-url") == 0, "the server was never asked")
    }

    /// The ticket request failed. The file is still on disk and the row is still staged — the whole
    /// upload is retried later, from the beginning, because nothing left this phone.
    @Test("a ticket request that fails backs the row off and leaves the file staged")
    func aTicketFailureBacksOff() async throws {
        let (entryId, mediaId) = try seed()
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let store = temporaryStagingStore()
        let staged = try store.stage(data: Data("pretend jpeg".utf8), as: mediaId, ext: "jpg")

        let performer = StubPerformer()
        performer.on("/v1/media/upload-url") { _ in (mediaErrorJSON("internal_error", "no"), 500) }
        let coordinator = MediaCoordinator(api: testClient(performer), store: store)

        let before = Date()
        await coordinator.beginUpload(mediaId: mediaId)

        let row = try #require(read(mediaId))
        #expect(row.state == .staged, "nothing was sent, so the row is exactly where it started")
        #expect(row.attemptCount == 1)
        let next = try #require(row.nextAttemptAt)
        #expect(next > before, "the retry is scheduled, not immediate")
        #expect(row.s3Key == nil)
        #expect(store.exists(staged), "the only copy of the photo must survive a failed ticket")
    }

    /// The server's numbers, stored rather than guessed.
    ///
    /// `chunk_bytes` is what the server used to decide how many parts there are, so a client that
    /// picks its own size produces the wrong count and completion fails. The parts are planned from
    /// it here, and the offsets have to tile the file exactly.
    ///
    /// **The ticket's part URLs are empty on purpose.** `dispatchParts` skips a part whose URL will
    /// not parse, and that is what keeps this file out of the process-wide background session — see
    /// the note at the top of this suite. Everything up to the dispatch is the real code path.
    @Test("a multipart ticket stores the server's key and chunk size and plans the parts")
    func aMultipartTicketIsPlanned() async throws {
        let chunk = 8_388_608
        let bytes = 20_971_520
        let (entryId, mediaId) = try seed(
            kind: "video", contentType: "video/mp4", bytes: bytes, stagedExtension: "mp4"
        )
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let store = temporaryStagingStore()
        // Existence is all `beginUpload` checks; the plan is arithmetic over `byteCount`, and
        // nothing on this path reads a byte of the file.
        try store.stage(data: Data("pretend mp4".utf8), as: mediaId, ext: "mp4")
        let key = "children/x/\(mediaId.uuidString.lowercased()).mp4"

        let performer = StubPerformer()
        performer.on("/v1/media/upload-url") { _ in
            (multipartTicketJSON(
                mediaId: mediaId,
                s3Key: key,
                parts: [(1, ""), (2, ""), (3, "")],
                chunkBytes: chunk
            ), 200)
        }
        let coordinator = MediaCoordinator(api: testClient(performer), store: store)

        await coordinator.beginUpload(mediaId: mediaId)

        let row = try #require(read(mediaId))
        #expect(row.s3Key == key)
        #expect(row.chunkBytes == chunk, "the server's number, never an assumed 8MB")
        #expect(row.state == .uploading)

        let parts = MediaUploader.parts(of: mediaId, in: storeContext())
        #expect(parts.map(\.partNumber) == [1, 2, 3])
        #expect(parts.map(\.offset) == [0, chunk, chunk * 2])
        #expect(parts.reduce(0) { $0 + $1.length } == bytes,
                "a full final chunk would upload padding past the end of the file")
        #expect(parts.allSatisfy { $0.etag == nil }, "a freshly planned part has landed nothing")
    }

    /// The guard at the top of `beginUpload`. A row the background session is already carrying must
    /// not be presigned again underneath it — that is the same bytes uploaded twice.
    @Test("a row that is already uploading is not started again")
    func anUploadingRowIsLeftAlone() async throws {
        let (entryId, mediaId) = try seed(state: .uploading)
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let performer = StubPerformer()
        let coordinator = MediaCoordinator(api: testClient(performer), store: temporaryStagingStore())

        await coordinator.beginUpload(mediaId: mediaId)

        #expect(performer.count(for: "upload-url") == 0)
        let row = try #require(read(mediaId))
        #expect(row.state == .uploading)
    }

    // MARK: - finishUpload

    /// **The truncation guard.** Storage assembles what it is given and calls it a success either
    /// way, so completing while a part has no ETag produces a video that will not play — and
    /// nothing anywhere says so.
    @Test("completion waits while any part is still outstanding")
    func completionDefersUntilEveryPartHasAnETag() async throws {
        let chunk = 8_388_608
        let (entryId, mediaId) = try seed(
            kind: "video", contentType: "video/mp4", bytes: 20_971_520,
            state: .uploaded, stagedExtension: "mp4", chunkBytes: chunk
        )
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let context = storeContext()
        for number in 1...3 {
            let part = MediaPart(
                mediaId: mediaId, partNumber: number, offset: (number - 1) * chunk,
                length: chunk, uploadURL: "https://storage.example/part\(number)"
            )
            // Two of the three landed. The third is the whole point.
            if number < 3 { part.etag = "etag-\(number)" }
            context.insert(part)
        }
        try context.save()

        let performer = StubPerformer()
        performer.on("/complete") { _ in (Data("{}".utf8), 200) }
        let coordinator = MediaCoordinator(api: testClient(performer), store: temporaryStagingStore())

        await coordinator.finishUpload(mediaId: mediaId)

        #expect(performer.count(for: "/complete") == 0,
                "one missing ETag is a truncated object, not a completable one")
        let row = try #require(read(mediaId))
        #expect(row.state == .uploaded, "still waiting, not failed — the last part is coming")
    }

    /// The handshake lands, and only then are the words considered.
    ///
    /// `PATCH /media/{id}/derived` resolves a media row the server has to already know about, so a
    /// transcript queued before `complete` succeeded would spend its attempts on 404s.
    @Test("completion marks the row and only then offers it for transcription")
    func completionEnqueuesTranscription() async throws {
        let (entryId, mediaId) = try seed(
            kind: "audio", contentType: AudioPipeline.contentType, bytes: 96_000,
            state: .uploaded, stagedExtension: AudioPipeline.fileExtension
        )
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let performer = StubPerformer()
        performer.on("/complete") { _ in (Data("{}".utf8), 200) }
        let api = testClient(performer)
        let coordinator = MediaCoordinator(api: api, store: temporaryStagingStore())
        // The queue reads through its own long-lived context, exactly as the app wires it — which
        // is the topology that makes "the row is complete by the time it is asked about" a real
        // question rather than a formality.
        coordinator.transcription = TranscriptionQueue(
            api: api,
            context: storeContext(),
            transcriber: StubTranscriber(),
            store: temporaryStagingStore()
        )

        await coordinator.finishUpload(mediaId: mediaId)

        #expect(performer.count(for: "/complete") == 1)
        let row = try #require(read(mediaId))
        #expect(row.state == .complete)
        #expect(row.attemptCount == 0)
        #expect(row.nextAttemptAt == nil)
        #expect(row.transcriptSync == TranscriptSync.queued,
                "the queue only promotes a row the server already acknowledges")
    }

    /// **The promise in the type's own header.** The bytes are in storage; only the acknowledgement
    /// failed. Re-uploading would spend a parent's cellular data to reach the state the row is
    /// already in.
    @Test("a failed acknowledgement retries the handshake and never the file")
    func aFailedCompletionStaysUploaded() async throws {
        let (entryId, mediaId) = try seed(
            kind: "audio", contentType: AudioPipeline.contentType, bytes: 96_000,
            state: .uploaded, stagedExtension: AudioPipeline.fileExtension
        )
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let performer = StubPerformer()
        performer.on("/complete") { _ in (mediaErrorJSON("internal_error", "later"), 500) }
        let api = testClient(performer)
        let coordinator = MediaCoordinator(api: api, store: temporaryStagingStore())
        coordinator.transcription = TranscriptionQueue(
            api: api,
            context: storeContext(),
            transcriber: StubTranscriber(),
            store: temporaryStagingStore()
        )

        let before = Date()
        await coordinator.finishUpload(mediaId: mediaId)

        let row = try #require(read(mediaId))
        #expect(row.state == .uploaded, "staged would re-send bytes storage already has")
        #expect(row.attemptCount == 1)
        let next = try #require(row.nextAttemptAt)
        #expect(next > before)
        #expect(row.transcriptSync == TranscriptSync.none,
                "nothing is queued against a row the server has not acknowledged")
    }

    /// The entry or the media row is gone server-side. Retrying cannot bring it back, so the row
    /// stops rather than spending six attempts proving it.
    @Test("a not_found on completion is terminal rather than retried")
    func aNotFoundOnCompletionIsTerminal() async throws {
        let (entryId, mediaId) = try seed(state: .uploaded)
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let performer = StubPerformer()
        performer.on("/complete") { _ in (mediaErrorJSON("not_found", "gone"), 404) }
        let coordinator = MediaCoordinator(api: testClient(performer), store: temporaryStagingStore())

        await coordinator.finishUpload(mediaId: mediaId)

        let row = try #require(read(mediaId))
        #expect(row.state == .failed)
        #expect(row.nextAttemptAt == nil, "nothing is scheduled, because nothing would help")
        #expect(row.attemptCount == 0, "this row did not fail an attempt, it ran out of subject")
    }

    /// Past the cap the row goes to `failed` — surfaced with a retry in Settings, never silently
    /// dropped and never spinning.
    @Test("acknowledgement failures stop at the cap")
    func completionStopsAtTheCap() async throws {
        let (entryId, mediaId) = try seed(state: .uploaded, attempts: UploadBackoff.maxAttempts - 1)
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let performer = StubPerformer()
        performer.on("/complete") { _ in (mediaErrorJSON("internal_error", "later"), 500) }
        let coordinator = MediaCoordinator(api: testClient(performer), store: temporaryStagingStore())

        await coordinator.finishUpload(mediaId: mediaId)

        let row = try #require(read(mediaId))
        #expect(row.attemptCount == UploadBackoff.maxAttempts)
        #expect(row.state == .failed)
        #expect(row.nextAttemptAt == nil)
        #expect(MediaCoordinator.failedMedia(in: storeContext()).contains { $0.id == mediaId },
                "a failed row has to stay visible to the parent rather than disappearing")
    }

    /// The guard at the top of `finishUpload`. Acknowledging bytes storage does not have yet is a
    /// 404 at best, and a row the server thinks is complete over nothing at worst.
    @Test("a row whose bytes are not in storage yet is never acknowledged")
    func aStagedRowIsNeverCompleted() async throws {
        let (entryId, mediaId) = try seed(state: .staged)
        defer { purge(entryId: entryId, mediaId: mediaId) }

        let performer = StubPerformer()
        performer.on("/complete") { _ in (Data("{}".utf8), 200) }
        let coordinator = MediaCoordinator(api: testClient(performer), store: temporaryStagingStore())

        await coordinator.finishUpload(mediaId: mediaId)

        #expect(performer.count(for: "/complete") == 0)
        let row = try #require(read(mediaId))
        #expect(row.state == .staged)
    }
}
