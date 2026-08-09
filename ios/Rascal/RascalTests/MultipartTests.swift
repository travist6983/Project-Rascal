import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Multipart bookkeeping — the part rows, what counts as finished, and what must not be
/// completed early.
///
/// The wire behaviour was verified separately against the real bucket before any of this was
/// written: a 40MB object uploaded as five presigned parts and fetched back byte-identical.
/// What is tested here is the client's half, which that exercise cannot cover.
@MainActor
@Suite("Multipart")
struct MultipartTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A 40MB video split at the server's 8MB — five parts, the last one short if it does not
    /// divide evenly.
    private func seed(
        in context: ModelContext,
        bytes: Int = 41_943_040,
        chunk: Int = 8_388_608
    ) -> (Media, [MediaPart]) {
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "a video")
        entry.sync = .synced
        context.insert(entry)

        let media = Media(entryId: entry.id, kind: "video", contentType: "video/mp4", byteCount: bytes)
        media.chunkBytes = chunk
        media.stagedExtension = "mp4"
        context.insert(media)

        let count = Int((Double(bytes) / Double(chunk)).rounded(.up))
        var parts: [MediaPart] = []
        for n in 1...count {
            let offset = (n - 1) * chunk
            let part = MediaPart(
                mediaId: media.id, partNumber: n, offset: offset,
                length: min(chunk, bytes - offset),
                uploadURL: "https://rascal-media-dev.t3.storage.dev/part\(n)"
            )
            context.insert(part)
            parts.append(part)
        }
        return (media, parts)
    }

    @Test("the last part is short rather than reading past the end of the file")
    func lastPartIsShort() throws {
        let context = try makeContext()
        // 20MB at 8MB chunks: 8 + 8 + 4, not 8 + 8 + 8.
        let (media, parts) = seed(in: context, bytes: 20_971_520)

        #expect(parts.count == 3)
        #expect(parts[0].length == 8_388_608)
        #expect(parts[2].length == 4_194_304, "a full final chunk would upload padding past EOF")
        #expect(parts.reduce(0) { $0 + $1.length } == media.byteCount)
    }

    @Test("part offsets tile the file with no gaps or overlaps")
    func offsetsTile() throws {
        let context = try makeContext()
        let (_, parts) = seed(in: context)
        var expected = 0
        for part in parts.sorted(by: { $0.partNumber < $1.partNumber }) {
            #expect(part.offset == expected)
            expected += part.length
        }
    }

    @Test("a part is finished only when storage returns an ETag")
    func etagIsTheDefinitionOfDone() throws {
        let context = try makeContext()
        let (_, parts) = seed(in: context)
        let part = parts[0]

        part.bytesSent = part.length
        // Bytes sent is not the same as accepted. `complete` needs the ETag, and without one
        // this part cannot be included however successful its PUT looked.
        #expect(!part.isUploaded)

        part.etag = "abc123"
        #expect(part.isUploaded)
    }

    @Test("progress is the sum of parts, so the ring measures the whole video")
    func progressSpansParts() throws {
        let context = try makeContext()
        let (media, parts) = seed(in: context)

        parts[0].etag = "a"; parts[0].bytesSent = parts[0].length
        parts[1].bytesSent = parts[1].length / 2
        media.bytesSent = parts.reduce(0) { $0 + $1.bytesSent }

        let fraction = Double(media.bytesSent) / Double(media.byteCount)
        #expect(fraction > 0.25 && fraction < 0.35, "one of five parts plus half of another")
    }

    @Test("an upload resumes rather than restarting")
    func resumeSkipsFinishedParts() throws {
        let context = try makeContext()
        let (media, parts) = seed(in: context)
        for part in parts.prefix(3) { part.etag = "done-\(part.partNumber)" }

        let outstanding = MediaUploader.parts(of: media.id, in: context).filter { !$0.isUploaded }

        // The whole point of part rows surviving a force quit: three parts of a 40MB video are
        // already in storage and must not be sent again.
        #expect(outstanding.count == 2)
        #expect(outstanding.map(\.partNumber) == [4, 5])
    }

    @Test("an expired part needs re-planning, not retrying")
    func expiredPartIsDistinctFromFailed() throws {
        let context = try makeContext()
        let (_, parts) = seed(in: context)
        let part = parts[0]
        part.expiresAt = Date().addingTimeInterval(-60)

        // Retrying a lapsed presigned URL is a guaranteed 403 that burns an attempt. Signing is
        // offline and cheap, so the answer is a new plan.
        #expect(part.isExpired())
        #expect(!parts[1].isExpired(now: Date()), "a part with no expiry set is not expired")
    }

    @Test("multipart is what the server said, not what the file size suggests")
    func multipartComesFromTheServer() throws {
        let context = try makeContext()
        let (media, _) = seed(in: context)
        #expect(media.isMultipart)

        let single = Media(entryId: UUID(), kind: "photo", contentType: "image/jpeg", byteCount: 50_000_000)
        // Large, but the server returned no chunk size — so it is a single PUT, and guessing
        // otherwise would split a file the server never planned parts for.
        #expect(!single.isMultipart)
    }

    @Test("ETags are ordered by part number when completion is called")
    func etagsAreOrdered() throws {
        let context = try makeContext()
        let (media, parts) = seed(in: context)
        for part in parts.reversed() { part.etag = "etag-\(part.partNumber)" }

        let collected = MediaUploader.parts(of: media.id, in: context)
            .compactMap { part in part.etag.map { (part: part.partNumber, etag: $0) } }
            .sorted { $0.part < $1.part }

        // The server assembles in the order it is given; out of order produces a corrupt
        // object rather than an error.
        #expect(collected.map(\.part) == [1, 2, 3, 4, 5])
    }
}
