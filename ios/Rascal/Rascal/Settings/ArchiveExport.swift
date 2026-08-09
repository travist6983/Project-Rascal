import Foundation

/// Downloading the whole archive as a zip.
///
/// This is the row that makes the product's promise checkable: an archive that outlives the
/// app is a claim until someone can actually hold the file. Everything here follows from that.
///
/// **Streamed to disk, never into memory.** A real archive is media, and media is large — the
/// development one is already 86MB and it is a fortnight old. `URLSessionDownloadTask` writes
/// to a file as bytes arrive, so the ceiling is disk rather than RAM, and `content-length` is
/// known up front because the server assembles the zip before it streams it. That is what makes
/// the progress bar a measurement rather than an animation.
@MainActor
@Observable
final class ArchiveExport {

    enum State: Equatable {
        case idle
        /// `fraction` is nil only if the server ever stops sending `content-length`; the bar
        /// falls back to indeterminate rather than inventing a number.
        case running(fraction: Double?)
        /// On disk and ready to hand to the share sheet.
        case ready(url: URL, bytes: Int64)
        /// Says what failed. Never red, never alarming — the archive is fine either way.
        case failed(String)
    }

    private(set) var state: State = .idle

    private let api: APIClient
    private var task: Task<Void, Never>?
    private let downloader = ArchiveDownloader()

    init(api: APIClient) {
        self.api = api
    }

    deinit {
        // A session holds its delegate until invalidated, so this is not optional tidiness.
        downloader.invalidate()
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Start, or restart after a failure. Safe to call twice; the second call is ignored while
    /// one is in flight rather than racing a second download onto the same file.
    func start(childId: UUID) {
        guard !isRunning else { return }
        state = .running(fraction: nil)

        // `owner` rather than reaching for `self` inside the hop. A capture-list binding read
        // from a *nested* concurrent closure counts as a captured var, which Swift 6 rejects;
        // an immutable local in between is the same weak reference and satisfies it. The class
        // is MainActor-isolated, so it is Sendable to hand across.
        downloader.onProgress = { [weak self] fraction in
            let owner = self
            Task { @MainActor in owner?.applyProgress(fraction) }
        }

        task = Task { [api, downloader] in
            do {
                let result = try await Self.download(
                    childId: childId, api: api, downloader: downloader
                )
                guard !Task.isCancelled else { return }
                self.state = .ready(url: result.url, bytes: result.bytes)
            } catch is CancellationError {
                self.state = .idle
            } catch let error as APIError {
                self.state = .failed(Self.explain(error))
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Ignored once the download has finished or been cancelled, so a late callback cannot put
    /// a finished export back into a running state.
    private func applyProgress(_ fraction: Double?) {
        guard isRunning else { return }
        state = .running(fraction: fraction)
    }

    /// Leaving the screen mid-export cancels it. The partial file goes with it — half an
    /// archive is not a smaller archive, it is a corrupt zip.
    func cancel() {
        task?.cancel()
        task = nil
        if case .ready = state {} else { state = .idle }
    }

    /// Forget a finished export and delete the file.
    ///
    /// Called when the share sheet is done with it. The zip is a copy of data that already
    /// exists on the server and on this phone; keeping it in the container would quietly cost
    /// the user the size of their archive, twice.
    func clear() {
        if case .ready(let url, _) = state {
            try? FileManager.default.removeItem(at: url)
        }
        task?.cancel()
        task = nil
        state = .idle
    }

    // MARK: The download

    private struct Result: Sendable {
        let url: URL
        let bytes: Int64
    }

    private nonisolated static func download(
        childId: UUID,
        api: APIClient,
        downloader: ArchiveDownloader
    ) async throws -> Result {
        let path = "v1/children/\(childId.uuidString.lowercased())/export"
        var request = try await api.authorizedRequest(.get, path)

        var outcome = try await downloader.run(request: request, childId: childId)

        // One retry after a refresh, the same discipline `sendRaw` uses. A parent who left the
        // app open over lunch should not be told their archive failed because a fifteen-minute
        // access token expired while they were deciding.
        if outcome.status == 401 {
            let refreshed = try await api.refreshSession()
            request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            outcome = try await downloader.run(request: request, childId: childId)
        }

        guard (200..<300).contains(outcome.status) else {
            // A non-2xx has a body, and it is small — the error envelope, kept in memory rather
            // than moved to the archive's destination.
            if let data = outcome.errorBody,
               let envelope = try? APIClient.decoder.decode(APIErrorEnvelope.self, from: data) {
                throw APIError.api(
                    code: envelope.error.code,
                    message: envelope.error.message,
                    field: envelope.error.field,
                    status: outcome.status
                )
            }
            throw APIError.unexpectedStatus(outcome.status)
        }

        guard let url = outcome.url else {
            throw APIError.transport("The archive downloaded but could not be saved.")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        return Result(url: url, bytes: bytes ?? outcome.expectedBytes)
    }

    /// Delete anything left in the exports directory.
    ///
    /// Called when the screen appears, which is the only moment nothing can be referencing one.
    /// Orphans are easy to make and impossible to notice: leaving the tab mid-download tears
    /// down the view while the task keeps running, and a force quit between the move and the
    /// share leaves a finished zip nobody will ever open. Tens or hundreds of megabytes of a
    /// copy of data that already exists twice is not something to leave lying around waiting
    /// for the system to feel memory pressure.
    static func purgeStale() {
        guard let folder = try? exportsFolder() else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `Caches`, not `Application Support`: this file is a copy of data that exists on the
    /// server and in the local store, so the system is welcome to reclaim it under pressure.
    /// Excluded from backup for the same reason — nobody wants their archive in iCloud twice.
    nonisolated static func exportsFolder() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var folder = caches.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    /// The server's own filename, which already encodes the child and the date —
    /// `rascal-miles-20260809.zip`. Parsed rather than reinvented so the file the parent saves
    /// is named the same everywhere.
    nonisolated static func filename(from response: HTTPURLResponse, childId: UUID) -> String {
        let fallback = "rascal-archive-\(childId.uuidString.prefix(8)).zip"
        guard let disposition = response.value(forHTTPHeaderField: "content-disposition"),
              let range = disposition.range(of: "filename=")
        else { return fallback }

        let raw = disposition[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
        // A header is not a path. Anything with a separator in it gets the fallback rather
        // than a chance to write outside the directory it was handed.
        guard !raw.isEmpty, !raw.contains("/"), !raw.contains("..") else { return fallback }
        return raw
    }

    /// Calm and specific: what failed, and the fact that nothing was lost. No red anywhere on
    /// this screen, and no language that suggests the archive is at risk — it is not.
    private nonisolated static func explain(_ error: APIError) -> String {
        switch error.code {
        case .notAuthorized:
            "Only a parent on this archive can export it."
        case .notFound:
            "That archive is no longer here."
        default:
            switch error {
            case .transport:
                "The download stopped. Your archive is safe on the server — try again when you have a steady connection."
            default:
                error.userMessage
            }
        }
    }
}

/// The download itself, and the only way to get byte progress out of one.
///
/// **`download(for:delegate:)` cannot do this.** The async variants take a per-task delegate for
/// `URLSessionTaskDelegate` callbacks, but `didWriteData` belongs to `URLSessionDownloadDelegate`
/// and is never delivered to it. Instrumenting the delegate proved it: zero callbacks across a
/// full 86MB transfer, on `URLSession.shared` and on a dedicated session alike, while the bar sat
/// at nothing and the row read as hung. Progress needs a classic **session-level** delegate and a
/// `URLSessionDownloadTask`, bridged back to async with a continuation.
///
/// Deliberately its own session rather than `MediaUploader.shared`. That one is process-wide by
/// necessity because a background *upload* delegate can be called into a process that has just
/// been launched to receive it; this is a foreground download a parent is watching, and giving
/// the upload session a second responsibility would be the wrong kind of reuse.
nonisolated final class ArchiveDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    struct Outcome: Sendable {
        let status: Int
        /// Set on success, once the file has been moved somewhere that outlives the callback.
        let url: URL?
        /// Set on a non-2xx: the error envelope, which is small enough to hold in memory.
        let errorBody: Data?
        let expectedBytes: Int64
    }

    /// Nil fraction when the server sends no `content-length`, which the export always does.
    ///
    /// Behind the lock like everything else here: the delegate is called on the session's own
    /// queue, and the setter is called from the main actor when a download starts.
    var onProgress: (@Sendable (Double?) -> Void)? {
        get { lock.withLock { storedOnProgress } }
        set { lock.withLock { storedOnProgress = newValue } }
    }

    // `nonisolated(unsafe)` on each, because every one of them is read and written **only**
    // under `lock`. The delegate is called on the session's own queue and the setters are called
    // from the main actor, so the mutual exclusion is real rather than assumed — the annotation
    // says the compiler cannot see it, not that it is absent.
    private nonisolated(unsafe) var storedOnProgress: (@Sendable (Double?) -> Void)?
    private let lock = NSLock()
    private nonisolated(unsafe) var continuation: CheckedContinuation<Outcome, Error>?
    private nonisolated(unsafe) var childId: UUID?
    private nonisolated(unsafe) var movedURL: URL?
    private nonisolated(unsafe) var errorBody: Data?
    private nonisolated(unsafe) var moveFailure: Error?
    private nonisolated(unsafe) var task: URLSessionDownloadTask?
    private nonisolated(unsafe) var storedSession: URLSession?

    /// Built on first use rather than in `init`, because the session takes `self` as its
    /// delegate and `self` is not available until `init` has finished.
    ///
    /// Spelled out by hand instead of `lazy var`: `lazy` is a mutable stored property, and a
    /// mutable stored property cannot be `nonisolated` — which this has to be, since the whole
    /// type lives off the main actor. The lock is not held by any caller when this runs, and
    /// `URLSession.init` does not call back into the delegate, so there is nothing to deadlock
    /// against.
    private var session: URLSession {
        lock.withLock {
            if let storedSession { return storedSession }
            let configuration = URLSessionConfiguration.default
            // A parent on a train should not lose an archive to a tunnel; the export is large
            // and worth waiting out.
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            storedSession = created
            return created
        }
    }

    /// Run one download to completion. One at a time — the caller guards that.
    func run(request: URLRequest, childId: UUID) async throws -> Outcome {
        lock.withLock {
            self.childId = childId
            movedURL = nil
            errorBody = nil
            moveFailure = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                lock.withLock {
                    self.continuation = continuation
                    self.task = task
                }
                task.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    /// A session delegate keeps the session alive until it is told otherwise.
    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let report = onProgress
        guard totalBytesExpectedToWrite > 0 else {
            report?(nil)
            return
        }
        report?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    /// **Everything here has to happen before this method returns.** The file at `location` is
    /// deleted the moment it does, so moving it is not something that can be deferred to a task.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(status),
              let http = downloadTask.response as? HTTPURLResponse,
              let childId = lock.withLock({ self.childId })
        else {
            // A refusal, not an archive. Kept in memory rather than moved into the exports
            // directory, where it would masquerade as a zip.
            let body = try? Data(contentsOf: location)
            lock.withLock { errorBody = body }
            return
        }

        do {
            let destination = try ArchiveExport.exportsFolder()
                .appending(path: ArchiveExport.filename(from: http, childId: childId))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { movedURL = destination }
        } catch {
            lock.withLock { moveFailure = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let resumed: CheckedContinuation<Outcome, Error>? = lock.withLock {
            defer { continuation = nil; self.task = nil }
            return continuation
        }
        guard let resumed else { return }

        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            resumed.resume(throwing: cancelled ? CancellationError() : APIError.transport(error.localizedDescription))
            return
        }
        if let moveFailure = lock.withLock({ self.moveFailure }) {
            resumed.resume(throwing: moveFailure)
            return
        }

        let http = task.response as? HTTPURLResponse
        resumed.resume(returning: Outcome(
            status: http?.statusCode ?? 0,
            url: lock.withLock { movedURL },
            errorBody: lock.withLock { errorBody },
            expectedBytes: http?.expectedContentLength ?? 0
        ))
    }
}


