import Foundation
import SwiftData
import Testing

@testable import Rascal

/// On-device transcription: what gets queued, what gets written, and in what order.
///
/// The assertions here are the specification. Where one of them and the implementation disagree,
/// the assertion is right — that has been true three times on this project, and the rules these
/// cover fail silently rather than visibly: a transcript that is never produced looks exactly
/// like a recording nobody has listened to.
@MainActor
@Suite("Transcription")
struct TranscriptionTests {

    private func queue(
        context: ModelContext,
        performer: StubPerformer,
        transcriber: StubTranscriber,
        store: StagingStore
    ) -> TranscriptionQueue {
        TranscriptionQueue(
            api: testClient(performer),
            context: context,
            transcriber: transcriber,
            store: store
        )
    }

    /// A performer that answers the derived write the way the API does.
    private func derivedPerformer(mediaId: UUID, entryId: UUID, transcript: String) -> StubPerformer {
        let performer = StubPerformer()
        performer.on("/derived") { _ in
            (derivedJSON(mediaId: mediaId, entryId: entryId, transcript: transcript), 200)
        }
        return performer
    }

    // MARK: 1 — A phone that cannot do this

    @Test("an unavailable model queues nothing, writes nothing, and changes nothing on screen")
    func unavailableIsSilent() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber(readiness: .unavailable)
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        let performer = StubPerformer()
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        // Nothing queued.
        #expect(media.transcriptSync == .none)
        // Nothing written — including no failure, because the row did nothing to earn one. A row
        // that burned its six attempts against a missing model would never transcribe on the day
        // the model arrived.
        #expect(media.transcript == nil)
        #expect(media.transcriptAttemptCount == 0)
        #expect(media.transcriptFailure == nil)
        // Nothing attempted and nothing sent.
        #expect(transcriber.callCount == 0)
        #expect(performer.requests.isEmpty)
    }

    @Test("a model still downloading queues the row and leaves it for later")
    func installingQueuesButDoesNotRun() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber(readiness: .installing)
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        let subject = queue(
            context: context, performer: StubPerformer(), transcriber: transcriber, store: store
        )

        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        // The model is coming, so the row waits for it rather than being written off.
        #expect(media.transcriptSync == .queued)
        #expect(media.transcript == nil)
        #expect(transcriber.callCount == 0)
        // Still no attempt recorded: the wait is not a failure.
        #expect(media.transcriptAttemptCount == 0)
    }

    // MARK: 2 — The locale fallback

    @Test("the device's own locale wins whenever a model for it is installed")
    func deviceLocaleWins() {
        let resolved = TranscriptionLocale.resolve(
            preferred: Locale(identifier: "es_MX"),
            installed: [Locale(identifier: "en-US"), Locale(identifier: "es-MX")]
        )
        #expect(resolved?.locale.language.languageCode?.identifier == "es")
        #expect(resolved?.isFallback == false)
    }

    @Test("a device locale with no installed model falls back to en-US, and says that it did")
    func fallsBackToEnglishAndRecordsIt() async throws {
        let resolved = try #require(TranscriptionLocale.resolve(
            preferred: Locale(identifier: "es_MX"),
            installed: [Locale(identifier: "en-US")]
        ))
        #expect(resolved.locale.language.languageCode?.identifier == "en")
        #expect(resolved.isFallback)

        // And the fallback is recorded on the row, not merely returned. An archive that cannot
        // say which model wrote a transcript cannot audit one that reads like nonsense.
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        let transcriber = StubTranscriber(readiness: .ready(resolved))
        let media = stagedVoiceNote(entryId: entryId, in: context, store: store)
        let performer = derivedPerformer(mediaId: media.id, entryId: entryId, transcript: "said something")
        transcriber.set(text: "said something")

        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)
        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        #expect(media.transcript == "said something")
        #expect(media.transcriptLocaleIdentifier == resolved.locale.identifier)
    }

    @Test("no installed model this device can use is unavailable, not a silent Spanish transcript")
    func noUsableModelResolvesToNothing() {
        #expect(TranscriptionLocale.resolve(
            preferred: Locale(identifier: "en-GB"),
            installed: [Locale(identifier: "es-MX")]
        ) == nil)
    }

    // MARK: 3 — Local first, then the push

    @Test("a successful transcription writes the row, then pushes it")
    func writesLocallyThenPushes() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        let transcriber = StubTranscriber()
        let media = stagedVoiceNote(entryId: entryId, in: context, store: store)
        let performer = derivedPerformer(
            mediaId: media.id, entryId: entryId,
            transcript: "and then the brachiosaurus ate the whole entire tree"
        )
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        #expect(media.transcript == "and then the brachiosaurus ate the whole entire tree")
        #expect(media.transcriptSync == .synced)
        #expect(performer.count(for: "/derived") == 1)
    }

    @Test("a push that fails leaves the words on the row, pending — the local write came first")
    func localWriteSurvivesAFailedPush() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber()
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        let performer = StubPerformer()
        performer.on("/derived") { _ in (Data("{}".utf8), 500) }
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        // This is the whole point of writing locally first: the network failed and the words
        // survived it. Nothing here had to be re-inferred.
        #expect(media.transcript == "and then the brachiosaurus ate the whole entire tree")
        #expect(media.transcriptSync == .pending)
        #expect(media.transcriptAttemptCount == 1)
        #expect(media.transcriptNextAttemptAt != nil)
    }

    // MARK: 4 — A crash between the two

    @Test("a row that crashed between the local write and the push pushes once, and only once")
    func retryAfterACrashIsIdempotent() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        // Exactly the state a crash leaves: words on the row, nothing sent.
        let media = stagedVoiceNote(
            entryId: entryId, in: context, store: store,
            transcriptState: .pending, transcript: "he said hangaburger"
        )
        let transcriber = StubTranscriber()
        let performer = derivedPerformer(mediaId: media.id, entryId: entryId, transcript: "he said hangaburger")
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        await subject.push()
        #expect(media.transcriptSync == .synced)
        #expect(performer.count(for: "/derived") == 1)

        // The retry that a sweep on the next foreground performs. The row is `synced`, so there
        // is nothing to send — no second derived write, and no second inference either.
        await subject.push()
        await subject.sweep()
        #expect(performer.count(for: "/derived") == 1)
        #expect(transcriber.callCount == 0)
    }

    // MARK: 5 — Bytes the server does not have yet

    @Test("media whose upload has not completed is never transcribed")
    func incompleteUploadIsNotTranscribed() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber()
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        // Back to mid-upload. `PATCH /media/{id}/derived` resolves a row the server has to
        // already know about, so transcribing now would spend the retry budget on 404s.
        media.state = .uploaded
        try? context.save()

        let performer = StubPerformer()
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)
        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        #expect(media.transcriptSync == .none)
        #expect(transcriber.callCount == 0)
        #expect(performer.requests.isEmpty)
        // And it is not offered in the backlog either, for the same reason.
        #expect(TranscriptionQueue.backlogCount(in: context) == 0)
    }

    @Test("a photo is not a voice note")
    func photosAreNotTranscribed() async throws {
        let context = try inMemoryContext()
        let media = completeMedia(entryId: UUID(), kind: "photo")
        context.insert(media)
        try context.save()

        #expect(!TranscriptionQueue.isTranscribable(media))
        #expect(TranscriptionQueue.backlogCount(in: context) == 0)
    }

    // MARK: 6 — Backoff, and the cap

    @Test("failures back off on the row and stop at the cap, with the reason recorded")
    func backoffCapsAndRecords() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber()
        transcriber.set(failure: TranscriptionFailure.engine("the analyzer gave up"))
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        media.transcriptSync = .queued
        try context.save()

        let subject = queue(
            context: context, performer: StubPerformer(), transcriber: transcriber, store: store
        )

        // Each sweep is one attempt, and each attempt is only eligible once the previous backoff
        // has elapsed — so the clock is wound forward rather than waited out.
        for attempt in 1...UploadBackoff.maxAttempts {
            media.transcriptNextAttemptAt = nil
            try context.save()
            await subject.sweep()
            #expect(media.transcriptAttemptCount == attempt)
        }

        #expect(media.transcriptSync == .failed)
        #expect(media.transcriptNextAttemptAt == nil)
        #expect(media.transcriptFailure == "Transcribing stopped: the analyzer gave up")
        #expect(media.transcript == nil)

        // Capped means capped: another sweep does not spend a seventh attempt.
        let spent = transcriber.callCount
        media.transcriptNextAttemptAt = nil
        try context.save()
        await subject.sweep()
        #expect(transcriber.callCount == spent)
    }

    @Test("a recording this phone cannot reach fails quietly rather than looping")
    func unreachableBytesFailQuietly() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        // No staged file and no `stagedExtension`: a row synced from another device.
        let media = completeMedia(entryId: UUID(), kind: "audio")
        media.transcriptSync = .queued
        context.insert(media)
        try context.save()

        let performer = StubPerformer()
        performer.on("/url") { _ in (Data("{}".utf8), 404) }
        let subject = queue(
            context: context, performer: performer, transcriber: StubTranscriber(), store: store
        )
        await subject.sweep()

        #expect(media.transcript == nil)
        #expect(media.transcriptAttemptCount == 1)
        #expect(media.transcriptFailure == TranscriptionFailure.bytesUnreachable.message)
    }

    // MARK: 7 — Relaunch

    @Test("a queued job survives a relaunch and resumes, because the queue is never in memory")
    func queuedWorkResumesAfterRelaunch() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        let transcriber = StubTranscriber()
        let media = stagedVoiceNote(entryId: entryId, in: context, store: store)
        let performer = derivedPerformer(
            mediaId: media.id, entryId: entryId,
            transcript: "and then the brachiosaurus ate the whole entire tree"
        )

        // Launch one: enqueue, then go away before the sweep runs.
        let first = queue(context: context, performer: performer, transcriber: transcriber, store: store)
        await first.enqueue(mediaId: media.id)
        #expect(media.transcriptSync == .queued)
        #expect(transcriber.callCount == 0)

        // Launch two. A brand new queue, carrying nothing from the first — which is the point:
        // eligibility is read off the row, so there is no in-memory list to lose.
        let second = queue(context: context, performer: performer, transcriber: transcriber, store: store)
        await second.sweep()

        #expect(media.transcriptSync == .synced)
        #expect(media.transcript == "and then the brachiosaurus ate the whole entire tree")
    }

    // MARK: 8 — The backlog

    @Test("the backlog counts what is missing, and only what this phone could supply")
    func backlogCounts() throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        _ = stagedVoiceNote(entryId: entryId, in: context, store: store)
        _ = stagedVoiceNote(entryId: entryId, in: context, store: store)
        // Already transcribed — not backlog.
        _ = stagedVoiceNote(entryId: entryId, in: context, store: store, transcriptState: .synced, transcript: "done")
        // A photo, and a voice note still uploading. Neither is work this can do.
        context.insert(completeMedia(entryId: entryId, kind: "photo"))
        let uploading = Media(entryId: entryId, kind: "audio", contentType: AudioPipeline.contentType, byteCount: 10)
        context.insert(uploading)
        try context.save()

        #expect(TranscriptionQueue.backlogCount(in: context) == 2)
    }

    @Test("a backlog run is serial, and reports what it did")
    func backlogRunsOneAtATime() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        let transcriber = StubTranscriber()
        transcriber.set(text: "words")
        let rows = (0..<3).map { _ in stagedVoiceNote(entryId: entryId, in: context, store: store) }
        // A plain UUID rather than the `@Model`: SwiftData rows are not `Sendable`, and the
        // performer's closures are. The body only has to parse, so any id will do.
        let anyMediaId = rows[0].id

        let performer = StubPerformer()
        performer.on("/derived") { _ in
            (derivedJSON(mediaId: anyMediaId, entryId: entryId, transcript: "words"), 200)
        }
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        let report = await subject.runBacklog()

        #expect(report.transcribed == 3)
        #expect(report.failed == 0)
        #expect(report.skipped == 0)
        #expect(!report.cancelled)
        // **One at a time.** Two analyzers running at once is twice the battery and twice the
        // heat on a phone somebody is holding, for an archive that is not waiting.
        #expect(transcriber.peakConcurrency == 1)
        #expect(rows.allSatisfy { $0.transcript == "words" })
        #expect(TranscriptionQueue.backlogCount(in: context) == 0)
    }

    @Test("a backlog run stops when asked, and keeps everything it already finished")
    func backlogIsCancellableAndResumable() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        let transcriber = StubTranscriber()
        transcriber.set(text: "words")
        // 400ms, not 80: the cancel has to hop to the main actor while row two is parked in
        // this delay, and 80ms is a thin margin on a contended runner.
        transcriber.set(delay: .milliseconds(400))
        for _ in 0..<4 { _ = stagedVoiceNote(entryId: entryId, in: context, store: store) }

        let performer = StubPerformer()
        performer.on("/derived") { _ in
            (derivedJSON(mediaId: UUID(), entryId: entryId, transcript: "words"), 200)
        }
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        // Stop the run from inside the run, once the *second* row starts — one finished, one
        // interrupted, two never begun. `onEnter` fires on the transcriber's own thread, so
        // there is no second task to schedule and nothing to race; the run is this test's own
        // task, awaited directly below.
        transcriber.onEnter { count in
            guard count == 2 else { return }
            Task { @MainActor in subject.cancelBacklog() }
        }
        let report = await subject.runBacklog()

        #expect(report.cancelled)
        #expect(report.transcribed < 4)
        #expect(report.transcribed >= 1, "the first row finished before the stop landed")
        let remaining = TranscriptionQueue.backlogCount(in: context)
        #expect(remaining > 0)
        // **Resumable, not restartable.** What finished stays finished, so pressing the button
        // again picks up from here rather than paying for the same inference twice.
        #expect(remaining == 4 - report.transcribed)

        transcriber.set(delay: .zero)
        let second = await subject.runBacklog()
        #expect(second.transcribed == remaining)
        #expect(TranscriptionQueue.backlogCount(in: context) == 0)
    }

    @Test("a backlog run delivers words that stalled, without paying for the inference twice")
    func backlogRetriesAStalledPush() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let entryId = UUID()
        // Transcribed, then the push spent all six attempts. Nothing retries this automatically —
        // `duePushes` looks for `.pending` on purpose — so without the backlog clearing it, these
        // words never reach the server.
        let media = stagedVoiceNote(
            entryId: entryId, in: context, store: store,
            transcriptState: .failed, transcript: "he said hangaburger"
        )
        media.transcriptAttemptCount = UploadBackoff.maxAttempts
        media.transcriptFailure = "The server had trouble."
        try context.save()
        let mediaId = media.id

        let transcriber = StubTranscriber()
        let performer = StubPerformer()
        performer.on("/derived") { _ in
            (derivedJSON(mediaId: mediaId, entryId: entryId, transcript: "he said hangaburger"), 200)
        }
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        // It is not in the inference backlog — there is nothing to transcribe — but it is
        // outstanding, and the row that offers this button says so.
        #expect(TranscriptionQueue.backlogCount(in: context) == 0)
        #expect(TranscriptionQueue.failedCount(in: context) == 1)

        await subject.runBacklog()

        #expect(media.transcriptSync == .synced)
        #expect(media.transcript == "he said hangaburger")
        #expect(media.transcriptFailure == nil)
        #expect(performer.count(for: "/derived") == 1)
        // The words were already on the row, so no second inference was paid for.
        #expect(transcriber.callCount == 0)
    }

    @Test("a phone that cannot run the model reports the backlog as skipped, not failed")
    func backlogSkipsWhenUnavailable() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber(readiness: .unavailable)
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        let subject = queue(
            context: context, performer: StubPerformer(), transcriber: transcriber, store: store
        )

        let report = await subject.runBacklog()

        #expect(report.skipped == 1)
        #expect(report.failed == 0)
        #expect(report.transcribed == 0)
        // Skipped is a fact about the phone, so the row is left exactly as it was found — no
        // attempt, no failure message, nothing for the next device to inherit.
        #expect(media.transcriptAttemptCount == 0)
        #expect(media.transcriptFailure == nil)
    }

    // MARK: 9 — Cancellation

    @Test("a cancelled transcription writes nothing at all — there is no partial to leave")
    func cancellationLeavesNoPartialTranscript() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber()
        transcriber.set(delay: .seconds(5))
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store, transcriptState: .queued)
        let performer = StubPerformer()
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        // Cancelled from inside the transcriber, before its five-second delay begins — the exact
        // moment cancellation has something to interrupt, on an idle laptop and a contended CI
        // runner alike.
        transcriber.onEnter { count in
            guard count == 1 else { return }
            Task { @MainActor in subject.cancelBacklog() }
        }
        _ = await subject.runBacklog()

        // The local write happens strictly after the transcriber returns, so a cancelled run has
        // no half-written state to clean up. Nothing was written, nothing was sent, and the row
        // is still waiting to be done properly.
        #expect(media.transcript == nil)
        #expect(media.transcriptSync == .queued)
        #expect(media.transcriptAttemptCount == 0)
        #expect(performer.requests.isEmpty)
    }

    // MARK: Silence

    @Test("a recording of a child who said nothing is finished, not failed and not empty")
    func silenceIsAnAnswer() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber()
        transcriber.set(text: "   ")
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        let performer = StubPerformer()
        let subject = queue(context: context, performer: performer, transcriber: transcriber, store: store)

        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        // No empty string in the archive — that would put a Transcript heading with nothing
        // under it on the detail screen forever — and nothing sent to the server either.
        #expect(media.transcript == nil)
        #expect(media.transcriptSync == .synced)
        #expect(performer.count(for: "/derived") == 0)
        #expect(TranscriptionQueue.backlogCount(in: context) == 0)
    }

    @Test("the segments the analyzer returns are joined into one readable line")
    func whitespaceIsTidiedOnce() {
        #expect(SpeechTranscription.tidy("  and then   the\n dinosaur  ") == "and then the dinosaur")
        #expect(SpeechTranscription.tidy("   ").isEmpty)
    }
}
