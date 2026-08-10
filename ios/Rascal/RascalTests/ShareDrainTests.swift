import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import Rascal

/// Turning what the extension staged into entries, and the two things that must hold however the
/// drain is interrupted: it never makes a second entry, and it never removes the only copy of a
/// photo before the server has the entry.
@MainActor
@Suite("Share drain")
struct ShareDrainTests {

    // MARK: Harness

    /// In-memory, so nothing touches the simulator's real container — the same arrangement
    /// `EntrySyncTests` uses.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([Entry.self, Media.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func temporaryInbox() -> ShareInbox {
        ShareInbox(directory: URL.temporaryDirectory.appending(path: "share-\(UUID().uuidString)"))
    }

    private func temporaryStaging() -> StagingStore {
        StagingStore(root: URL.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)"))
    }

    private struct Harness {
        let drain: ShareDrain
        let inbox: ShareInbox
        let staging: StagingStore
        let context: ModelContext
        let childId: UUID
    }

    private func harness() throws -> Harness {
        let inbox = temporaryInbox()
        let staging = temporaryStaging()
        let context = try makeContext()
        let childId = UUID()
        return Harness(
            drain: ShareDrain(inbox: inbox, staging: staging, context: context, childId: childId),
            inbox: inbox, staging: staging, context: context, childId: childId
        )
    }

    /// A tiny real JPEG, optionally dated, so the drain runs the real `ImagePipeline` rather than
    /// a stub of it. The conversion is the part that must not be reimplemented, so the test makes
    /// it actually happen.
    private func imageData(dateTimeOriginal: String? = nil) -> Data {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.35, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        )!
        var properties: [CFString: Any] = [:]
        if let dateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// Stage `count` photos into the inbox and write one record naming all of them — exactly the
    /// shape the extension leaves behind.
    @discardableResult
    private func stageShare(
        _ harness: Harness,
        photos count: Int = 1,
        dateTimeOriginal: String? = nil,
        note: String? = nil,
        occurredAt: Date = Date(timeIntervalSince1970: 1_562_250_600),
        createdAt: Date = Date(timeIntervalSince1970: 1_786_000_000)
    ) throws -> PendingShare {
        var items: [PendingShare.Item] = []
        for _ in 0..<count {
            let mediaId = UUID()
            let source = URL.temporaryDirectory.appending(path: "src-\(UUID().uuidString).jpg")
            try imageData(dateTimeOriginal: dateTimeOriginal).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }

            let staged = try harness.inbox.stage(copyingFrom: source, as: mediaId, ext: "jpg")
            items.append(PendingShare.Item(
                id: mediaId, filename: staged.filename, kind: .photo,
                byteCount: staged.byteCount, capturedAt: nil
            ))
        }

        let record = PendingShare(
            createdAt: createdAt,
            occurredAt: occurredAt,
            occurredAtSource: .captureMetadata,
            note: note,
            media: items
        )
        try harness.inbox.write(record)
        return record
    }

    private func entries(_ context: ModelContext) -> [Entry] {
        (try? context.fetch(FetchDescriptor<Entry>())) ?? []
    }

    private func media(_ context: ModelContext) -> [Media] {
        (try? context.fetch(FetchDescriptor<Media>())) ?? []
    }

    // MARK: One share, one entry

    /// **Multiple selected assets become one entry with multiple media, not one entry per photo.**
    /// Three pictures of the same afternoon are one thing that happened, and the composer has
    /// treated a multi-select that way since phase 2.
    @Test("three shared photos become one entry holding three media")
    func multipleAssetsBecomeOneEntry() async throws {
        let harness = try harness()
        let record = try stageShare(harness, photos: 3)

        let result = await harness.drain.ingest()

        #expect(result.ingested == 1)
        #expect(result.mediaStaged == 3)
        #expect(result.mediaSkipped == 0)

        let entries = entries(harness.context)
        #expect(entries.count == 1, "a multi-select produced \(entries.count) entries")

        let entry = try #require(entries.first)
        #expect(entry.id == record.id, "the entry did not take the extension's id")
        #expect(entry.childId == harness.childId)
        #expect(entry.assignmentId == nil, "a share is freeform; it links to no assignment")
        #expect(entry.sync == .pending)
        #expect(entry.existsOnServer == false)

        let media = media(harness.context)
        #expect(media.count == 3)
        #expect(media.allSatisfy { $0.entryId == entry.id })
        #expect(Set(media.map(\.id)) == Set(record.media.map(\.id)), "media ids were not carried over")
    }

    /// The archive is JPEG, upright, with a thumbnail beside it — `ImagePipeline`'s decisions,
    /// which `docs/decisions.md` calls effectively permanent. A share sheet producing anything
    /// else would put two kinds of photo in one archive.
    @Test("the shared file is converted by the existing pipeline, into the app's own staging")
    func convertsThroughTheExistingPipeline() async throws {
        let harness = try harness()
        try stageShare(harness, photos: 1)

        await harness.drain.ingest()

        let one = try #require(media(harness.context).first)
        #expect(one.kind == "photo")
        #expect(one.contentType == "image/jpeg")
        #expect(one.stagedExtension == "jpg")
        #expect(one.state == .staged)
        #expect(one.hasThumbnail, "without this the staging sweep will not keep the original")
        #expect(one.byteCount > 0)

        let original = harness.staging.originalURL(for: one.id, ext: "jpg")
        #expect(harness.staging.exists(original), "the converted bytes are not in the app's staging store")
        #expect(harness.staging.exists(harness.staging.thumbnailURL(for: one.id)))

        // JPEG magic number — the bytes, not the label.
        let bytes = try Data(contentsOf: original)
        #expect(bytes.prefix(2) == Data([0xFF, 0xD8]))
    }

    /// `occurred_at` is the extension's, and `created_at` is the moment the share was saved —
    /// never re-stamped to whenever the app next happened to open. The two are never conflated,
    /// and this is where that rule is most likely to be broken by accident.
    @Test("occurred_at and created_at both come from the record, and stay distinct")
    func datesComeFromTheRecord() async throws {
        let harness = try harness()
        let occurred = Date(timeIntervalSince1970: 1_562_250_600)
        let created = Date(timeIntervalSince1970: 1_786_000_000)
        try stageShare(harness, occurredAt: occurred, createdAt: created)

        await harness.drain.ingest()

        let entry = try #require(entries(harness.context).first)
        #expect(entry.occurredAt == occurred, "a 2019 photo was not filed in 2019")
        #expect(entry.createdAt == created)
        #expect(entry.occurredAt != entry.createdAt)
    }

    @Test("a note becomes the entry's body, and no note is nil rather than empty")
    func noteBecomesBody() async throws {
        let withNote = try harness()
        try stageShare(withNote, note: "he ate the whole thing")
        await withNote.drain.ingest()
        #expect(try #require(entries(withNote.context).first).body == "he ate the whole thing")

        let without = try harness()
        try stageShare(without)
        await without.drain.ingest()
        #expect(try #require(entries(without.context).first).body == nil)
    }

    // MARK: Idempotency

    /// **Draining twice produces exactly one entry.** The guarantee is the entry id living in the
    /// record: the second pass finds the row and writes nothing.
    @Test("draining twice produces exactly one entry")
    func drainingTwiceMakesOneEntry() async throws {
        let harness = try harness()
        try stageShare(harness, photos: 2)

        let first = await harness.drain.ingest()
        let second = await harness.drain.ingest()

        #expect(first.ingested == 1)
        #expect(second.ingested == 0)
        #expect(second.alreadyPresent == 1)
        #expect(entries(harness.context).count == 1)
        #expect(media(harness.context).count == 2, "the second pass added media rows")
    }

    /// **The app killed after the entry landed but before its media uploaded.** The next
    /// foreground runs the whole drain again from the top; nothing may be duplicated and nothing
    /// may be lost — the bytes are still staged and still due.
    @Test("a drain interrupted before the upload resumes without duplicating anything")
    func resumesAfterInterruptionBeforeUpload() async throws {
        let harness = try harness()
        try stageShare(harness, photos: 2)

        await harness.drain.ingest()
        let entry = try #require(entries(harness.context).first)
        let mediaIds = Set(media(harness.context).map(\.id))
        #expect(media(harness.context).allSatisfy { $0.state == .staged })

        // The interruption: the sweep never ran, so nothing is on the server. Then a relaunch.
        harness.drain.reap()
        let resumed = await harness.drain.ingest()

        #expect(resumed.alreadyPresent == 1)
        #expect(entries(harness.context).count == 1)
        #expect(entries(harness.context).first?.id == entry.id)
        #expect(Set(media(harness.context).map(\.id)) == mediaIds, "media rows were remade")
        #expect(media(harness.context).allSatisfy { $0.state == .staged }, "outstanding uploads were lost")

        // And the staged bytes are still there for the uploader to find.
        for one in media(harness.context) {
            #expect(harness.staging.exists(harness.staging.originalURL(for: one.id, ext: "jpg")))
        }
    }

    /// Soft deletes are how this app deletes. A share drained and then thrown away must not come
    /// back on the next launch.
    @Test("a share whose entry was deleted is not drained a second time")
    func deletedEntryIsNotRecreated() async throws {
        let harness = try harness()
        try stageShare(harness)

        await harness.drain.ingest()
        let entry = try #require(entries(harness.context).first)
        entry.deletedAt = Date()
        try harness.context.save()

        let again = await harness.drain.ingest()
        #expect(again.ingested == 0)
        #expect(again.alreadyPresent == 1)
        #expect(entries(harness.context).count == 1)
    }

    // MARK: Reaping — only after the server has it

    /// **Staged files are removed only after the entry is confirmed created server-side.** The
    /// bytes exist nowhere else once Photos is closed, so reaping on ingest would mean a failed
    /// `POST /entries` had already thrown away the parent's only copy.
    @Test("the inbox copy survives until the server has acknowledged the entry")
    func reapsOnlyAfterServerConfirmation() async throws {
        let harness = try harness()
        let record = try stageShare(harness, photos: 2)

        await harness.drain.ingest()

        // Ingested, not yet pushed. Everything must still be in the container.
        var reaped = harness.drain.reap()
        #expect(reaped.reaped == 0)
        #expect(harness.inbox.pending().count == 1)
        for item in record.media {
            let url = try #require(harness.inbox.mediaURL(for: item))
            #expect(FileManager.default.fileExists(atPath: url.path), "a staged file went early")
        }

        // A failed push is not a confirmation either.
        let entry = try #require(entries(harness.context).first)
        entry.sync = .failed
        reaped = harness.drain.reap()
        #expect(reaped.reaped == 0, "a failed push was read as confirmation")
        #expect(harness.inbox.pending().count == 1)

        // `existsOnServer` is set by `Entry.applyServerResponse` and by nothing else.
        entry.existsOnServer = true
        entry.sync = .synced
        try harness.context.save()

        reaped = harness.drain.reap()
        #expect(reaped.reaped == 1)
        #expect(harness.inbox.pending().isEmpty)
        for item in record.media {
            let url = try #require(harness.inbox.mediaURL(for: item))
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        // And the app's own staged copies are untouched — the media has not uploaded yet, and
        // those are the bytes the uploader is going to send.
        for one in media(harness.context) {
            #expect(harness.staging.exists(harness.staging.originalURL(for: one.id, ext: "jpg")))
        }
    }

    /// Without this the record sits in the container forever, retried on every launch against an
    /// entry that exists precisely so it can be gone.
    @Test("a deleted entry reaps its inbox copy even though the server never heard of it")
    func deletedEntryReaps() async throws {
        let harness = try harness()
        try stageShare(harness)
        await harness.drain.ingest()

        let entry = try #require(entries(harness.context).first)
        entry.deletedAt = Date()
        try harness.context.save()

        #expect(harness.drain.reap().reaped == 1)
        #expect(harness.inbox.pending().isEmpty)
    }

    @Test("reaping runs the orphan sweep, so a cancelled share does not accumulate")
    func reapSweepsOrphans() async throws {
        let harness = try harness()
        let source = URL.temporaryDirectory.appending(path: "src-\(UUID().uuidString).jpg")
        try imageData().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        // Bytes with no record: a cancel, or an extension killed before it wrote one.
        try harness.inbox.stage(copyingFrom: source, as: UUID(), ext: "jpg")

        #expect(harness.drain.reap().orphansSwept == 1)
    }

    // MARK: What cannot be recovered

    /// The same situation `MediaCoordinator.beginUpload` calls unrecoverable when a staged
    /// original has vanished. The bytes are gone, nothing can bring them back, and creating an
    /// empty entry from a photo share would be a lie about what the parent saved.
    @Test("a record whose files are all gone, with nothing written on it, is not made into an entry")
    func unrecoverableRecordIsNotAnEmptyEntry() async throws {
        let harness = try harness()
        let record = try stageShare(harness, photos: 1)

        for item in record.media {
            let url = try #require(harness.inbox.mediaURL(for: item))
            try FileManager.default.removeItem(at: url)
        }

        let result = await harness.drain.ingest()
        #expect(result.ingested == 0)
        #expect(result.unrecoverable == 1)
        #expect(entries(harness.context).isEmpty, "an empty entry was invented from a lost photo")
        #expect(harness.inbox.pending().isEmpty, "the record would be retried forever")
    }

    /// A note is real content the parent typed. Losing the photo does not make the words
    /// worthless, and the entry is a legitimate text entry — one of the three completion shapes.
    @Test("a lost photo with a note still becomes the note")
    func noteSurvivesALostPhoto() async throws {
        let harness = try harness()
        let record = try stageShare(harness, photos: 1, note: "the first time he said it")

        for item in record.media {
            try FileManager.default.removeItem(at: #require(harness.inbox.mediaURL(for: item)))
        }

        let result = await harness.drain.ingest()
        #expect(result.ingested == 1)
        #expect(result.mediaSkipped == 1)

        let entry = try #require(entries(harness.context).first)
        #expect(entry.body == "the first time he said it")
        #expect(media(harness.context).isEmpty)
    }

    /// One unreadable file must not take the rest of the share down with it.
    @Test("one unconvertible file is skipped and the others still land")
    func oneBadFileDoesNotSinkTheShare() async throws {
        let harness = try harness()
        let record = try stageShare(harness, photos: 3)

        // Overwrite one staged file with something no decoder will take.
        let broken = try #require(harness.inbox.mediaURL(for: record.media[1]))
        try Data("not an image".utf8).write(to: broken)

        let result = await harness.drain.ingest()
        #expect(result.ingested == 1)
        #expect(result.mediaStaged == 2)
        #expect(result.mediaSkipped == 1)
        #expect(entries(harness.context).count == 1)
        #expect(media(harness.context).count == 2)
    }

    // MARK: Degradation

    @Test("a drain with no App Group container does nothing rather than failing")
    func noContainerIsQuiet() async throws {
        let context = try makeContext()
        let drain = ShareDrain(
            inbox: ShareInbox(directory: nil),
            staging: temporaryStaging(),
            context: context,
            childId: UUID()
        )

        #expect(await drain.ingest() == ShareDrain.Result())
        #expect(drain.reap() == ShareDrain.Result())
        #expect(entries(context).isEmpty)
    }

    @Test("an empty inbox is a no-op on every launch")
    func emptyInboxIsANoOp() async throws {
        let harness = try harness()
        #expect(await harness.drain.ingest() == ShareDrain.Result())
        #expect(harness.drain.reap() == ShareDrain.Result())
    }
}

/// The words the share sheet says.
///
/// Here rather than in the extension because the extension is its own module and the test host is
/// the app — see `ShareCopy`. The date sentence is the most consequential copy in the phase: it is
/// the only warning a parent gets before a photo from another year is filed under this week.
@MainActor
@Suite("Share copy")
struct ShareCopyTests {

    @Test("the heading names photos and videos rather than counting items")
    func heading() {
        #expect(ShareCopy.heading(photos: 1, videos: 0) == "1 photo")
        #expect(ShareCopy.heading(photos: 3, videos: 0) == "3 photos")
        #expect(ShareCopy.heading(photos: 0, videos: 1) == "1 video")
        #expect(ShareCopy.heading(photos: 2, videos: 1) == "2 photos and 1 video")
        #expect(ShareCopy.heading(photos: 0, videos: 0) == "Nothing to save")
    }

    @Test("a read date says where it was read from; a stood-in date says that it stood in")
    func dateExplanation() {
        #expect(
            ShareCopy.dateExplanation(source: .captureMetadata, kinds: [.photo])
                == "Read from the photo."
        )
        #expect(
            ShareCopy.dateExplanation(source: .captureMetadata, kinds: [.video])
                == "Read from the video."
        )
        #expect(
            ShareCopy.dateExplanation(source: .captureMetadata, kinds: [.photo, .video])
                == "The earliest date on these files."
        )

        // **Whole sentences, not prefixes.** The first version of these two asserted a prefix and
        // a substring, and passed on "These files don't say when it *was* taken" — a plural
        // subject with a singular verb, which a screenshot caught and this suite did not. A
        // partial assertion on a sentence tests that the sentence exists, not that it reads.
        #expect(
            ShareCopy.dateExplanation(source: .shareTime, kinds: [.photo])
                == "This photo doesn't say when it was taken, so today is standing in. You can change it in Rascal."
        )
        #expect(
            ShareCopy.dateExplanation(source: .shareTime, kinds: [.video, .video])
                == "These videos don't say when they were taken, so today is standing in. You can change it in Rascal."
        )
        #expect(
            ShareCopy.dateExplanation(source: .shareTime, kinds: [.photo, .video])
                == "These files don't say when they were taken, so today is standing in. You can change it in Rascal."
        )
    }

    /// **The tone rule, asserted.** Nothing on this screen may scold, count down, or imply a
    /// mistake was made — a date that stood in is a fact about the file, not a failure.
    @Test("nothing the share sheet says is an alarm")
    func toneIsQuiet() {
        let all = [
            ShareCopy.dateExplanation(source: .shareTime, kinds: [.photo]),
            ShareCopy.dateExplanation(source: .shareTime, kinds: [.photo, .photo]),
            ShareCopy.dateExplanation(source: .captureMetadata, kinds: [.photo]),
            ShareCopy.unusableKind,
            ShareCopy.unusableContainer,
            ShareCopy.saveHint(mediaCount: 1),
            ShareCopy.saveHint(mediaCount: 4),
        ]
        for sentence in all {
            let lowered = sentence.lowercased()
            for forbidden in ["error", "failed", "invalid", "warning", "unable", "!"] {
                #expect(!lowered.contains(forbidden), "\"\(sentence)\" contains \"\(forbidden)\"")
            }
        }
    }

    /// A parent sharing five photos should know they are making one entry, not five.
    @Test("the save hint says one entry, whatever the count")
    func saveHint() {
        #expect(ShareCopy.saveHint(mediaCount: 1) == "Files one entry")
        #expect(ShareCopy.saveHint(mediaCount: 4) == "Files one entry holding all 4")
    }

    /// A thumbnail says nothing to a screen reader.
    @Test("every preview tile reads as what it is and where it is in the row")
    func mediaLabels() {
        #expect(ShareCopy.mediaLabel(kind: .photo, position: 1, of: 1, durationSeconds: nil) == "Photo")
        #expect(ShareCopy.mediaLabel(kind: .photo, position: 2, of: 3, durationSeconds: nil) == "Photo 2 of 3")
        #expect(
            ShareCopy.mediaLabel(kind: .video, position: 1, of: 2, durationSeconds: 64)
                == "Video 1 of 2, 1 minute 4 seconds"
        )
    }

    @Test("the date capsule carries the composer's vocabulary")
    func dateLabel() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        #expect(ShareCopy.dateLabel(now, now: now) == "Today")
        let older = now.addingTimeInterval(-400 * 24 * 3600)
        #expect(ShareCopy.dateLabel(older, now: now) != "Today")
        #expect(ShareCopy.dateLabel(older, now: now).contains("2025"))
    }
}
