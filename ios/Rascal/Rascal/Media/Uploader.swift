import Foundation
import SwiftData

/// Carries staged files to object storage on a background session.
///
/// A background `URLSession` keeps uploading while the app is suspended and resumes after a
/// force quit, which is the only reason a photo taken on cellular in a parking lot reliably
/// arrives. That capability comes with three rules that are not negotiable:
///
/// 1. **One session, one identifier, one delegate, for the process lifetime.** Two sessions
///    sharing an identifier is a crash, not a warning.
/// 2. **File-based uploads.** A background session cannot carry an in-memory body; a
///    `Data`-based task silently becomes a foreground one.
/// 3. **The delegate establishes its own model context before reading anything.** The system
///    can relaunch the app *into* a delegate callback with nothing restored. Waiting for the
///    app to hand over a container means the callback lands nowhere and the upload finishes
///    without ever being marked — the failure that looks like a stalled upload and isn't.
final class MediaUploader: NSObject {

    static let shared = MediaUploader()

    /// Stable across launches; the system matches outstanding tasks to it after a relaunch.
    static let sessionIdentifier = "com.travisterry.childarchive.upload"

    /// Called when the background queue drains after a system relaunch. UIKit hands this in
    /// via `handleEventsForBackgroundURLSession`; not calling it is how uploads appear to
    /// stall for minutes.
    var backgroundCompletionHandler: (@Sendable () -> Void)?

    /// Built once, lazily, so the identifier is claimed exactly once per process.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // The archive can wait; the parent's battery and data plan cannot. The system decides
        // when to send, which is the whole point of a background session.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Rule 3. Never a stored context — a context outlives its usefulness across a relaunch,
    /// and the delegate may run before any exists.
    private func makeContext() -> ModelContext {
        ModelContext(LocalStore.shared)
    }

    private override init() { super.init() }

    /// Claim the session eagerly at launch so outstanding background tasks reattach to this
    /// delegate rather than being reported to nobody.
    func activate() {
        _ = session
    }

    // MARK: Starting an upload

    /// Begin carrying one *part* of a staged file.
    ///
    /// A background session cannot upload a subrange of a file, and it cannot upload `Data` at
    /// all — so each part is written to its own temporary file first. That costs one extra copy
    /// of `chunk_bytes` on disk (8MB) rather than holding the whole video in memory, which is
    /// the trade a 700MB interview makes worth taking.
    func startPart(
        mediaId: UUID,
        partNumber: Int,
        sourceFile: URL,
        offset: Int,
        length: Int,
        to uploadURL: URL
    ) {
        guard let slice = Self.writeSlice(of: sourceFile, offset: offset, length: length,
                                          named: "\(mediaId.uuidString)-\(partNumber)") else { return }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"

        let task = session.uploadTask(with: request, fromFile: slice)
        // Both ids, because a part callback has to find its row and its parent.
        task.taskDescription = "\(mediaId.uuidString)#\(partNumber)"
        task.resume()
    }

    /// Extract a byte range to a temporary file, reading in blocks so a large video is never
    /// resident in memory.
    private static func writeSlice(of source: URL, offset: Int, length: Int, named: String) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? handle.close() }

        let destination = FileManager.default.temporaryDirectory.appending(path: "\(named).part")
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let out = try? FileHandle(forWritingTo: destination)
        else { return nil }
        defer { try? out.close() }

        try? handle.seek(toOffset: UInt64(offset))
        var remaining = length
        let block = 1 << 20
        while remaining > 0 {
            let want = min(block, remaining)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            try? out.write(contentsOf: chunk)
            remaining -= chunk.count
        }
        return destination
    }

    /// Begin carrying one staged file. The row must already have an `s3Key` and a presigned
    /// destination — see `MediaCoordinator`, which owns the ordering.
    func start(mediaId: UUID, from fileURL: URL, to uploadURL: URL, contentType: String) {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        // File-based, per rule 2. `fromFile:` is what makes this survive suspension.
        let task = session.uploadTask(with: request, fromFile: fileURL)
        // The only channel back to the row: a background task is identified by this across a
        // relaunch, when nothing else about the original call site still exists.
        task.taskDescription = mediaId.uuidString
        task.resume()
    }

    /// Tasks the system is still tracking, so a sweep does not start a second upload for
    /// something already in flight.
    func inFlightMediaIds() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }
}

// MARK: - Delegate

extension MediaUploader: URLSessionDataDelegate {

    /// Progress. Written to the row rather than published, so it survives the view that
    /// started it going away.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let route = Self.route(task) else { return }
        let context = makeContext()

        if let partNumber = route.part {
            guard let part = Self.part(mediaId: route.mediaId, number: partNumber, in: context) else { return }
            part.bytesSent = Int(totalBytesSent)
            // The parent's progress is the sum of its parts, so the ring measures the whole
            // video rather than whichever part happens to be in flight.
            if let media = Self.media(id: route.mediaId, in: context) {
                if media.state != .uploading { media.state = .uploading }
                media.bytesSent = Self.parts(of: route.mediaId, in: context).reduce(0) { $0 + $1.bytesSent }
            }
            try? context.save()
            return
        }

        guard let media = Self.media(id: route.mediaId, in: context) else { return }
        if media.state != .uploading { media.state = .uploading }
        // The real number, not a spinner. The ring in F-2 is drawn from this.
        media.bytesSent = Int(totalBytesSent)
        try? context.save()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Context first, before touching anything. Rule 3.
        let context = makeContext()

        guard let route = Self.route(task) else { return }

        if let partNumber = route.part {
            finishPart(route.mediaId, partNumber, task: task, error: error, context: context)
            return
        }

        guard let media = Self.media(id: route.mediaId, in: context) else { return }

        if error != nil {
            // A retry re-sends from the start, so the ring must not keep a stale high-water
            // mark and appear to go backwards on the next attempt.
            media.bytesSent = 0
            media.recordAttemptFailure()
            try? context.save()
            return
        }

        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            media.recordAttemptFailure()
            try? context.save()
            return
        }

        // The ETag is captured because it is genuinely useful — an integrity check now, and
        // the mechanism multipart will need. It is deliberately **not** required: the server
        // ignores `etags` unless `s3_upload_id` is set, so gating completion on a header that
        // may be absent would strand an upload that actually succeeded.
        media.etag = response?.value(forHTTPHeaderField: "ETag")
        media.bytesSent = media.byteCount
        media.state = .uploaded
        media.attemptCount = 0
        media.nextAttemptAt = nil
        try? context.save()

        // Storage has the bytes; the server does not know yet. `MediaCoordinator` finishes the
        // handshake, and the sweep retries this leg independently of re-uploading.
        Task { [id = route.mediaId] in await MediaCoordinator.shared?.finishUpload(mediaId: id) }
    }

    /// One part landed. The media row is only `uploaded` once every part has an ETag —
    /// storage has the bytes but has assembled nothing until `complete` is called with all of
    /// them, which is the difference from the single-PUT path.
    private func finishPart(
        _ mediaId: UUID,
        _ partNumber: Int,
        task: URLSessionTask,
        error: Error?,
        context: ModelContext
    ) {
        // The slice file has served its purpose either way; leaving them accumulates a second
        // copy of every video in tmp.
        let slice = FileManager.default.temporaryDirectory
            .appending(path: "\(mediaId.uuidString)-\(partNumber).part")
        try? FileManager.default.removeItem(at: slice)

        guard let part = Self.part(mediaId: mediaId, number: partNumber, in: context) else { return }
        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0

        guard error == nil, (200..<300).contains(status),
              let etag = response?.value(forHTTPHeaderField: "ETag")
        else {
            // No ETag means not finished, however successful the PUT looked — `complete`
            // cannot be called without one for every part.
            part.bytesSent = 0
            part.attemptCount += 1
            part.nextAttemptAt = UploadBackoff.nextAttempt(after: part.attemptCount)
            if let media = Self.media(id: mediaId, in: context), part.nextAttemptAt == nil {
                media.state = .failed
            }
            try? context.save()
            return
        }

        part.etag = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        part.bytesSent = part.length
        part.attemptCount = 0
        part.nextAttemptAt = nil

        let all = Self.parts(of: mediaId, in: context)
        if let media = Self.media(id: mediaId, in: context) {
            media.bytesSent = all.reduce(0) { $0 + $1.bytesSent }
            if all.allSatisfy(\.isUploaded) {
                media.state = .uploaded
                media.attemptCount = 0
                media.nextAttemptAt = nil
            }
        }
        try? context.save()

        if all.allSatisfy(\.isUploaded) {
            Task { await MediaCoordinator.shared?.finishUpload(mediaId: mediaId) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Must be on the main queue, and must actually be called — the system waits for it
        // before letting the app suspend again.
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }

    /// A task carries either a media id or `mediaId#partNumber`. Parsing it here keeps the
    /// encoding in one place — it is the only channel that survives a relaunch.
    static func route(_ task: URLSessionTask) -> (mediaId: UUID, part: Int?)? {
        guard let raw = task.taskDescription else { return nil }
        let pieces = raw.split(separator: "#", maxSplits: 1)
        guard let id = UUID(uuidString: String(pieces[0])) else { return nil }
        return (id, pieces.count > 1 ? Int(pieces[1]) : nil)
    }

    private static func part(mediaId: UUID, number: Int, in context: ModelContext) -> MediaPart? {
        var descriptor = FetchDescriptor<MediaPart>(
            predicate: #Predicate { $0.mediaId == mediaId && $0.partNumber == number }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func parts(of mediaId: UUID, in context: ModelContext) -> [MediaPart] {
        let all = (try? context.fetch(FetchDescriptor<MediaPart>())) ?? []
        return all.filter { $0.mediaId == mediaId }.sorted { $0.partNumber < $1.partNumber }
    }

    private static func media(id: UUID, in context: ModelContext) -> Media? {
        var descriptor = FetchDescriptor<Media>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
