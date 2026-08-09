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
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let context = makeContext()
        guard let media = Self.media(id: id, in: context) else { return }
        if media.state != .uploading { media.state = .uploading }
        // The real number, not a spinner. The ring in F-2 is drawn from this.
        media.bytesSent = Int(totalBytesSent)
        try? context.save()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Context first, before touching anything. Rule 3.
        let context = makeContext()

        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
              let media = Self.media(id: id, in: context)
        else { return }

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
        Task { await MediaCoordinator.shared?.finishUpload(mediaId: id) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Must be on the main queue, and must actually be called — the system waits for it
        // before letting the app suspend again.
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }

    private static func media(id: UUID, in context: ModelContext) -> Media? {
        var descriptor = FetchDescriptor<Media>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
