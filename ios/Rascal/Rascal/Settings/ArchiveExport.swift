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
    private let progress = DownloadProgress()

    init(api: APIClient) {
        self.api = api
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
        progress.onProgress = { [weak self] fraction in
            let owner = self
            Task { @MainActor in owner?.applyProgress(fraction) }
        }

        task = Task { [api, progress] in
            do {
                let result = try await Self.download(childId: childId, api: api, progress: progress)
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
        progress: DownloadProgress
    ) async throws -> Result {
        let path = "v1/children/\(childId.uuidString.lowercased())/export"
        var request = try await api.authorizedRequest(.get, path)

        var (temporary, response) = try await URLSession.shared.download(
            for: request, delegate: progress
        )

        // One retry after a refresh, the same discipline `sendRaw` uses. A parent who left the
        // app open over lunch should not be told their archive failed because a fifteen-minute
        // access token expired while they were deciding.
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            try? FileManager.default.removeItem(at: temporary)
            let refreshed = try await api.refreshSession()
            request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            (temporary, response) = try await URLSession.shared.download(
                for: request, delegate: progress
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // A non-2xx still has a body, and it is small — the error envelope, written to the
            // same temporary file the zip would have been.
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let data = try? Data(contentsOf: temporary),
               let envelope = try? APIClient.decoder.decode(APIErrorEnvelope.self, from: data) {
                throw APIError.api(
                    code: envelope.error.code,
                    message: envelope.error.message,
                    field: envelope.error.field,
                    status: http.statusCode
                )
            }
            throw APIError.unexpectedStatus(http.statusCode)
        }

        // Moved out of the system's temporary slot immediately: the URL handed back by
        // `download(for:)` is only guaranteed to exist until this call returns.
        let destination = try stagedDestination(named: filename(from: http, childId: childId))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)

        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        return Result(url: destination, bytes: bytes ?? http.expectedContentLength)
    }

    /// The server's own filename, which already encodes the child and the date —
    /// `rascal-miles-20260809.zip`. Parsed rather than reinvented so the file the parent saves
    /// is named the same everywhere.
    private nonisolated static func filename(from response: HTTPURLResponse, childId: UUID) -> String {
        guard let disposition = response.value(forHTTPHeaderField: "content-disposition"),
              let range = disposition.range(of: "filename=")
        else { return "rascal-archive-\(childId.uuidString.prefix(8)).zip" }

        let raw = disposition[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
        // A header is not a path. Anything with a separator in it gets the fallback rather
        // than a chance to write outside the directory it was handed.
        guard !raw.isEmpty, !raw.contains("/"), !raw.contains("..") else {
            return "rascal-archive-\(childId.uuidString.prefix(8)).zip"
        }
        return raw
    }

    /// `Caches`, not `Application Support`: this file is a copy of data that exists on the
    /// server and in the local store, so the system is welcome to reclaim it under pressure.
    /// Excluded from backup for the same reason — nobody wants their archive in iCloud twice.
    private nonisolated static func stagedDestination(named name: String) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var folder = caches.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder.appending(path: name)
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

/// Byte progress for one download.
///
/// A per-task delegate rather than a shared session delegate: this is a foreground download the
/// parent is watching, not the background upload path, and it must not be confused with
/// `MediaUploader`'s session — that one is a process-wide singleton by necessity and adding a
/// second responsibility to it would be the wrong kind of reuse.
nonisolated final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Nil fraction when the server sends no `content-length`, which the export always does.
    var onProgress: (@Sendable (Double?) -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            onProgress?(nil)
            return
        }
        onProgress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    /// Required by the protocol. The async `download(for:delegate:)` hands the file back through
    /// its return value, so there is nothing to do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
