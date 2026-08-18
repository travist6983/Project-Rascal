import Foundation
import OSLog
import SwiftData

/// Turns voice notes into words, and gets those words to the server.
///
/// ## Why this is not a second queue
///
/// The retry policy is `UploadBackoff` — the same one the upload legs use, not a copy of it. The
/// schedule lives on the media row as `transcriptNextAttemptAt`, beside `nextAttemptAt`, for the
/// same reason: backoff that resets on relaunch is not backoff. The entry point is
/// `MediaCoordinator.sweep()`, which is called by `EntrySync.sweep()`, which is called by
/// `SyncEngine.pull()` — one sweep, on one trigger, in one order. What lives here is the code,
/// not a second mechanism.
///
/// ## The two legs, and why they are separate
///
/// **Inference** produces text. It is expensive, local, and cannot be retried usefully more than
/// a few times — if the model will not read a file it will not read it in ten minutes either.
/// **The push** delivers that text. It is cheap, remote, and absolutely worth retrying for days.
/// A row is on exactly one of them at a time, which is why one `transcriptAttemptCount` serves
/// both.
///
/// ## Durability
///
/// There is no in-memory list of pending work anywhere in this file. Eligibility is read off the
/// row every time, so "the queue survives relaunch" is not a feature that had to be built — it is
/// a consequence of never holding the queue in memory. A job interrupted mid-inference left
/// `transcriptSync == .queued` and no transcript, which is exactly the state the next run looks
/// for. A job interrupted between the local write and the push left `.pending` with a transcript,
/// which is exactly what the push leg looks for, and the server's endpoint is idempotent.
@MainActor
@Observable
final class TranscriptionQueue {

    private static let log = Logger(subsystem: "app.rascal", category: "transcription")

    /// How far a backlog run has got. Nil when none is running.
    struct Progress: Equatable, Sendable {
        var completed: Int
        var total: Int
    }

    /// What a backlog run did. Reported plainly at the end and never as a score.
    struct Report: Equatable, Sendable {
        var transcribed = 0
        /// The model could not serve this device or this locale. Not a failure — a fact about
        /// the phone, and the rows are left exactly as they were.
        var skipped = 0
        var failed = 0
        /// The parent stopped it. Everything already done stays done.
        var cancelled = false

        var attempted: Int { transcribed + skipped + failed }
    }

    private(set) var progress: Progress?
    private(set) var lastReport: Report?

    private let api: APIClient
    private let context: ModelContext
    private let transcriber: SpeechTranscribing
    /// Where a downloaded copy is written while it is being read. Not the staging store: staging
    /// holds files on their way *to* the server, and these are coming back from it.
    private let scratch: URL

    /// **One transcription at a time, process-wide.** Two analyzers running against two
    /// recordings is twice the battery and twice the thermal load on a phone somebody is holding
    /// while parenting, for no gain — the archive is not waiting on this.
    private var running = false
    /// The in-flight backlog run, so it can be stopped.
    private var backlogTask: Task<Report, Never>?

    /// Where the recordings this phone made already live.
    private let store: StagingStore

    init(
        api: APIClient,
        context: ModelContext,
        transcriber: SpeechTranscribing = SpeechTranscription(),
        store: StagingStore = StagingStore(),
        scratch: URL = FileManager.default.temporaryDirectory
    ) {
        self.api = api
        self.context = context
        self.transcriber = transcriber
        self.store = store
        self.scratch = scratch
    }

    var isRunning: Bool { running }

    // MARK: - Enqueuing

    /// A recording has finished uploading. Consider it, opportunistically.
    ///
    /// **The only automatic trigger there is.** It names one row and never enumerates, which is
    /// what keeps a first launch from walking six years of archive: the pre-feature backlog sits
    /// at `.none` and only the Settings action promotes it.
    ///
    /// A device that cannot transcribe leaves the row untouched at `.none` — nothing queued,
    /// nothing written, and an app that looks exactly as it did yesterday.
    func enqueue(mediaId: UUID) async {
        guard let media = Self.media(id: mediaId, in: context),
              Self.isTranscribable(media),
              media.transcriptSync == .none
        else { return }

        switch await transcriber.readiness(preferring: .current) {
        case .ready, .installing:
            // `installing` queues too. The model is coming, the row should be waiting for it,
            // and a row queued against a download that never finishes renders identically to one
            // that was never queued.
            media.transcriptSync = .queued
            try? context.save()
        case .unavailable:
            return
        }
    }

    // MARK: - The sweep

    /// One pass: deliver anything already written, then produce at most one new transcript.
    ///
    /// **Delivery before inference**, and the order matters. Words already on the phone are one
    /// request away from being permanent; words not yet produced cost a battery. If the sweep has
    /// only one of the two to give, it should be the cheap one that ends a risk.
    ///
    /// At most one inference per sweep on purpose. The sweep runs on every foreground, and a
    /// foreground is not a licence to hold the device warm — a second queued row waits for the
    /// next one, which is soon.
    func sweep(now: Date = Date()) async {
        await push(now: now)
        await transcribeNext(now: now)
    }

    /// Deliver every transcript the server has not acknowledged.
    ///
    /// Not capped the way inference is: these are small JSON requests, and a phone that has been
    /// offline for a week should catch up in one foreground rather than one row per foreground.
    func push(now: Date = Date()) async {
        for media in Self.duePushes(in: context, now: now) {
            await pushOne(media, now: now)
        }
    }

    /// **Local write first, then the push.** `recordTranscript` has already run by the time
    /// anything here does, so a crash at any point in this function loses nothing: the row still
    /// carries the words, still reads `.pending`, and the next sweep tries again against an
    /// endpoint the API documents as idempotent — the same transcript twice changes nothing.
    private func pushOne(_ media: Media, now: Date) async {
        guard let transcript = media.transcript, !transcript.isEmpty else { return }
        do {
            let updated = try await api.writeDerived(mediaId: media.id, transcript: transcript)
            media.transcriptSync = .synced
            media.transcriptAttemptCount = 0
            media.transcriptNextAttemptAt = nil
            media.transcriptFailure = nil
            // The server's own `updated_at`, so the next pull compares two server values rather
            // than one of ours against one of theirs — the same reasoning as `planMedia`.
            media.updatedAt = updated.updatedAt
            try? context.save()
        } catch let error as APIError where error.code == .notFound {
            // The media row is gone server-side. Retrying cannot bring it back, and the words
            // have nowhere to land.
            media.transcriptSync = .failed
            media.transcriptFailure = "That recording is no longer in the archive."
            media.transcriptNextAttemptAt = nil
            try? context.save()
        } catch {
            media.recordTranscriptFailure(Self.describe(error), now: now)
            try? context.save()
        }
    }

    /// Produce one transcript, if a row is due for one.
    @discardableResult
    private func transcribeNext(now: Date) async -> Bool {
        guard !running else { return false }
        guard let media = Self.dueInference(in: context, now: now).first else { return false }
        return await transcribe(media, now: now) == .transcribed
    }

    // MARK: - The backlog

    /// Every voice note the archive has no words for, on rows this phone could do something about.
    ///
    /// Includes `.none` — which the automatic path deliberately excludes — because this is the
    /// count behind a button somebody has to press.
    ///
    /// Excludes `.synced`, and that exclusion is not the same as "has a transcript". A recording
    /// of a child who said nothing comes back settled with no words, and counting it as backlog
    /// would offer it up for re-inference on every run, forever, for the same silence.
    static func backlog(in context: ModelContext) -> [Media] {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { isTranscribable($0) && $0.transcript == nil && $0.transcriptSync != .synced }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func backlogCount(in context: ModelContext) -> Int {
        backlog(in: context).count
    }

    /// Rows that produced a transcript and could not deliver it, or could not produce one.
    /// Surfaced so the backlog row can say so, never as an error over the archive.
    static func failedCount(in context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { $0.deletedAt == nil && $0.transcriptSync == .failed }
            .count
    }

    /// Words this phone has and the server does not, on a row that has stopped trying.
    ///
    /// Not in `backlog` — there is nothing to transcribe, and re-running inference over a
    /// recording whose transcript is already sitting on the row would be paying twice for the
    /// same words. A backlog run clears these first; see `drainBacklog`.
    static func stalledPushes(in context: ModelContext) -> [Media] {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { $0.deletedAt == nil && $0.transcriptSync == .failed && $0.transcript != nil }
    }

    /// Work the backlog, oldest-newest first, one at a time, until it is done or stopped.
    ///
    /// Resumable in the way that matters: a row is promoted out of `.none` immediately before its
    /// own inference, so a kill mid-run leaves at most one row mid-flight and every finished row
    /// finished. Pressing the button again picks up from there rather than starting over — and a
    /// run that is never pressed again never happens, which is what keeps a manual action manual.
    @discardableResult
    func runBacklog() async -> Report {
        if let existing = backlogTask { return await existing.value }

        let task = Task<Report, Never> { [weak self] in
            guard let self else { return Report() }
            return await self.drainBacklog()
        }
        backlogTask = task
        let report = await task.value
        backlogTask = nil
        return report
    }

    func cancelBacklog() {
        backlogTask?.cancel()
    }

    /// Dismiss the summary of the last run, so the row goes back to offering the next one.
    func clearReport() {
        lastReport = nil
    }

    private func drainBacklog() async -> Report {
        var report = Report()

        // **Stalled deliveries first, and they are not part of the inference count.** A row whose
        // push spent all six attempts sits at `.failed` carrying words the server has never seen,
        // and nothing retries it automatically — `duePushes` looks for `.pending` on purpose, or a
        // dead network would be re-attempted forever. Someone pressing this button is the signal
        // to try again, and delivering words already produced is far cheaper than producing them.
        let stalled = Self.stalledPushes(in: context)
        if !stalled.isEmpty {
            for media in stalled { media.resetTranscriptForManualRun() }
            try? context.save()
            await push()
        }

        let targets = Self.backlog(in: context).map(\.id)
        progress = Progress(completed: 0, total: targets.count)
        defer {
            progress = nil
            lastReport = report
        }

        for id in targets {
            if Task.isCancelled {
                report.cancelled = true
                Self.log.notice("backlog run stopped after \(report.attempted, privacy: .public)")
                return report
            }
            guard let media = Self.media(id: id, in: context), Self.isTranscribable(media) else {
                // Deleted or completed underneath the run. Not an outcome worth counting.
                progress?.completed += 1
                continue
            }
            // Cleared here rather than in bulk: a row nobody reaches keeps whatever the last
            // automatic attempt recorded about it.
            media.resetTranscriptForManualRun()
            if media.transcriptSync == .none { media.transcriptSync = .queued }
            try? context.save()

            switch await transcribe(media, now: Date()) {
            case .transcribed: report.transcribed += 1
            case .skipped: report.skipped += 1
            case .failed: report.failed += 1
            case .cancelled:
                report.cancelled = true
                return report
            }
            progress?.completed += 1
        }
        return report
    }

    // MARK: - One transcription

    private enum Outcome: Equatable {
        case transcribed, skipped, failed, cancelled
    }

    /// The whole of one job: check, fetch, transcribe, write, push.
    ///
    /// Serialised by `running` rather than by an actor, because everything here already runs on
    /// the main actor — the `ModelContext` the app's views read from lives there. The inference
    /// itself is inside `SpeechAnalyzer`, which is its own actor and does its work off this one.
    private func transcribe(_ media: Media, now: Date) async -> Outcome {
        guard !running else { return .skipped }
        running = true
        defer { running = false }

        let readiness = await transcriber.readiness(preferring: .current)
        guard case .ready(let locale) = readiness else {
            // Unavailable or still downloading. **No attempt is recorded** — a device that cannot
            // transcribe must not accumulate failures it did nothing to earn, and a row that
            // burned its six attempts against a missing model would never transcribe on the day
            // the model arrived.
            return .skipped
        }

        let mediaId = media.id
        var input: (url: URL, isTemporary: Bool)
        switch await resolveInput(for: media) {
        case .success(let resolved):
            input = resolved
        case .failure(let reason):
            media.recordTranscriptFailure(reason.message, now: now)
            try? context.save()
            return .failed
        }
        defer { if input.isTemporary { try? FileManager.default.removeItem(at: input.url) } }

        // **A video usually needs nothing done to it**, which was the surprise of phase 16:
        // `AVAudioFile(forReading:)` reads the audio track straight out of an mp4, so the export
        // the phase was specified around turned out to be machinery for a problem that does not
        // exist. What is genuinely needed is the silence check — without it a clip with no audio
        // track fails to open and is recorded as an unreachable recording, burning six retries
        // against a video that never had sound.
        var extractedTrack: URL?
        // Its own `defer`: the download above may also have left a temporary file, and both have
        // to go on every path out of here.
        defer { if let extractedTrack { try? FileManager.default.removeItem(at: extractedTrack) } }

        if media.mediaKind == .video {
            let trackURL = scratch.appending(
                path: "vtrack-\(mediaId.uuidString.lowercased()).\(AudioPipeline.fileExtension)"
            )
            do {
                switch try await VideoAudioTrack.plan(for: input.url, exportingTo: trackURL) {
                case .readDirectly:
                    break
                case .extracted(let url):
                    extractedTrack = url
                    input = (url, false)  // cleanup is the `defer` above, not this tuple's flag
                case .silent:
                    // **Not a failure.** The same answer as a recording of a child who would not
                    // talk, and it takes the same path: done, attempts reset, nothing written.
                    media.transcriptSync = .synced
                    media.transcriptAttemptCount = 0
                    media.transcriptNextAttemptAt = nil
                    try? context.save()
                    return .transcribed
                }
            } catch {
                media.recordTranscriptFailure(Self.describe(error), now: now)
                try? context.save()
                return .failed
            }
        }

        let produced: String
        do {
            produced = try await transcriber.transcribe(fileURL: input.url, in: locale)
        } catch is CancellationError {
            // **Nothing written.** The local write is strictly after this call returns, so a
            // cancelled run cannot leave a partial transcript — there is no partial state to
            // leave. The row is untouched and stays queued.
            return .cancelled
        } catch {
            media.recordTranscriptFailure(Self.describe(error), now: now)
            try? context.save()
            return .failed
        }

        // **Trimmed here, not trusted from the transcriber.** `SpeechTranscription` tidies its own
        // output, but this is what a protocol boundary means: the queue decides what goes in the
        // archive, and a conformer that returned a single space would otherwise write one into a
        // permanent record. A test caught exactly that.
        let text = produced.trimmingCharacters(in: .whitespacesAndNewlines)

        // Silence is an answer. A recording of a four-year-old refusing to talk is a complete,
        // legitimate entry, and writing an empty string would put an empty Transcript heading on
        // its detail screen forever.
        guard !text.isEmpty else {
            media.transcriptSync = .synced
            media.transcriptAttemptCount = 0
            media.transcriptNextAttemptAt = nil
            try? context.save()
            return .transcribed
        }

        // Re-read: the row may have been deleted while the analyzer was running, and writing
        // onto a gravestone would put words in an archive the parent has emptied.
        guard let row = Self.media(id: mediaId, in: context), row.deletedAt == nil else {
            return .skipped
        }
        row.recordTranscript(text, locale: locale)
        try? context.save()
        if locale.isFallback {
            Self.log.notice("transcribed \(mediaId, privacy: .public) with the \(locale.locale.identifier, privacy: .public) fallback")
        }

        await pushOne(row, now: now)
        return .transcribed
    }

    /// The file to read, and whether this function created it.
    ///
    /// The staged original is preferred and used **in place** — not copied, not re-encoded. It is
    /// there for every recording made on this phone, because a voice note has no thumbnail and
    /// `stagedOriginalIsDisposable` therefore never becomes true for one.
    ///
    /// A row synced from another device has no local file, and the backlog is mostly those. Those
    /// bytes are fetched back through the presigned read — which is the only reason this returns
    /// a flag rather than just a URL.
    private func resolveInput(
        for media: Media
    ) async -> Result<(url: URL, isTemporary: Bool), TranscriptionFailure> {
        if let ext = media.stagedExtension {
            let staged = store.originalURL(for: media.id, ext: ext)
            if FileManager.default.fileExists(atPath: staged.path) {
                return .success((staged, false))
            }
        }
        // The container matters now that video is eligible: writing mp4 bytes to a `.m4a` path
        // leaves `AVURLAsset` sniffing content to recover from a name we chose wrongly.
        let ext = media.mediaKind == .video ? "mp4" : AudioPipeline.fileExtension
        let destination = scratch.appending(
            path: "transcribe-\(media.id.uuidString.lowercased()).\(ext)"
        )
        switch await MediaAccess.downloadToFile(
            mediaId: media.id, destination: destination, api: api
        ) {
        case .success(let fetched):
            return .success((fetched, true))
        case .failure(.networkTooExpensive):
            // Deferred, not failed. It still burns an attempt so a phone permanently on cellular
            // stops asking, and the row says why — the words are coming, on a different network.
            return .failure(.waitingForWiFi)
        case .failure(.unreachable):
            return .failure(.bytesUnreachable)
        }
    }

    // MARK: - Selection

    /// Voice notes the server has, that this phone is allowed to work on.
    ///
    /// **Audio and video, and `complete` only.** Incomplete upload is the same discipline as
    /// entries-before-media in the upload sweep: `PATCH /media/{id}/derived` resolves a media row
    /// the server has to already know about, so transcribing first would spend the whole retry
    /// budget on 404s.
    ///
    /// **Video joined in phase 16**, once the transcriber had been seen working on a real device.
    /// It is the same path and not a second one — and it turned out to need less than the phase
    /// was specified around, because `AVAudioFile` reads an mp4's audio track directly.
    static func isTranscribable(_ media: Media) -> Bool {
        media.deletedAt == nil
            && (media.mediaKind == .audio || media.mediaKind == .video)
            && media.isComplete
    }

    /// Rows with words to deliver. `.pending` only — `.failed` has spent its budget and waits
    /// for someone to ask, even though its transcript stays protected from the pull.
    static func duePushes(in context: ModelContext, now: Date = Date()) -> [Media] {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { media in
                media.deletedAt == nil
                    && media.transcriptSync == .pending
                    && media.transcript != nil
                    && UploadBackoff.isEligible(nextAttemptAt: media.transcriptNextAttemptAt, now: now)
            }
            .sorted { $0.transcriptSweepOrderKey < $1.transcriptSweepOrderKey }
    }

    /// Rows waiting for words. Ordered by when each became due, for the reason `dueMedia` is —
    /// a row that keeps failing sinks on its own instead of starving the queue behind it.
    static func dueInference(in context: ModelContext, now: Date = Date()) -> [Media] {
        ((try? context.fetch(FetchDescriptor<Media>())) ?? [])
            .filter { media in
                media.awaitsTranscription
                    && UploadBackoff.isEligible(nextAttemptAt: media.transcriptNextAttemptAt, now: now)
            }
            .sorted { $0.transcriptSweepOrderKey < $1.transcriptSweepOrderKey }
    }

    // MARK: - Scaffolding

    private static func media(id: UUID, in context: ModelContext) -> Media? {
        var descriptor = FetchDescriptor<Media>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? TranscriptionFailure { return failure.message }
        if let api = error as? APIError { return api.userMessage }
        return error.localizedDescription
    }
}

extension Media {
    /// Ordering key for both transcription legs, matching `sweepOrderKey`'s reasoning exactly:
    /// a row never attempted sorts first, and each failure pushes its own row further back.
    var transcriptSweepOrderKey: Date {
        transcriptNextAttemptAt ?? .distantPast
    }
}
