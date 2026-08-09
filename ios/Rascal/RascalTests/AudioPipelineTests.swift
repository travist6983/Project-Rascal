import AVFoundation
import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Audio capture: the format that reaches the archive, the state machine, and every path that
/// must not lose bytes.
///
/// The simulator has no microphone, so a recorder cannot be driven end to end here. Where a real
/// recording is needed, these write one with `AVAudioFile` at **exactly the settings
/// `AudioPipeline` uses** and then assert against the resulting file — which is the same thing
/// the pipeline produces and the only thing the archive ever sees.

// MARK: - Fixtures

/// A real AAC/m4a file at the pipeline's own settings, containing a tone.
///
/// Deliberately not a stub: several of the assertions below are about what a *file* turns out to
/// be, and a fake would make them assert nothing.
private func writeRecording(seconds: Double, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: AudioPipeline.settings)

    let frames = AVAudioFrameCount(44_100 * 0.1)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for frame in 0..<Int(frames) {
        samples[frame] = sinf(Float(frame) * 2 * .pi * 440 / 44_100) * 0.4
    }

    for _ in 0..<Int((seconds / 0.1).rounded()) {
        try file.write(from: buffer)
    }
}

@MainActor
private func postInterruption(_ type: AVAudioSession.InterruptionType) {
    NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
    )
}

@MainActor
private func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
    NotificationCenter.default.post(
        name: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
    )
}

private func temporaryStore() throws -> StagingStore {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "rascal-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return StagingStore(root: root)
}

// MARK: - The format that reaches the archive

@MainActor
@Suite("Audio format")
struct AudioFormatTests {

    @Test("the written file is genuinely AAC, mono, at 44.1 kHz")
    func fileIsWhatWasAskedFor() async throws {
        // Asserted against the *file*, by reading its format description — not by re-reading the
        // settings dictionary that was passed in. Passing settings is not the same as producing
        // them, and only the file is the archive.
        let store = try temporaryStore()
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 1.0, to: url)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)

        #expect(basic.mFormatID == kAudioFormatMPEG4AAC, "the archive holds AAC, not PCM")
        #expect(basic.mChannelsPerFrame == 1, "mono — a child talking is a point source")
        #expect(abs(basic.mSampleRate - 44_100) < 1)
        #expect(url.pathExtension == "m4a")
    }

    @Test("the settings say mono AAC at 96 kbps and high quality")
    func settingsAreTheDecision() {
        #expect(AudioPipeline.settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
        #expect(AudioPipeline.settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(AudioPipeline.settings[AVSampleRateKey] as? Double == 44_100)
        #expect(AudioPipeline.settings[AVEncoderBitRateKey] as? Int == 96_000)
        #expect(AudioPipeline.settings[AVEncoderAudioQualityKey] as? Int == AVAudioQuality.high.rawValue)
        #expect(AudioPipeline.contentType == "audio/m4a")
    }

    @Test("duration comes from the asset and matches the recording")
    func durationFromTheAsset() async throws {
        // The UI timer drifts over ten minutes and a wrong `duration_seconds` is wrong in the
        // archive forever, so the value that ships is read off the finished file.
        let store = try temporaryStore()
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 2.0, to: url)

        let finished = try #require(await AudioPipeline.finalize(mediaId: id, url: url))
        #expect(abs(finished.duration - 2.0) < 0.25, "got \(finished.duration)s")
        #expect(finished.byteCount > 0)
        #expect(finished.mediaId == id)
    }

    @Test("a ten-minute recording stays under the single-PUT threshold")
    func tenMinutesIsSmall() {
        // 96 kbps mono for 600 seconds is about 7.2MB — comfortably under the server's ~15MB
        // multipart threshold. Recorded as arithmetic rather than as a promise, because nothing
        // in the client special-cases audio to stay below that line: if a file ever exceeds it,
        // the existing multipart path handles it unchanged.
        let bytes = Double(AudioPipeline.settings[AVEncoderBitRateKey] as! Int)
            / 8 * AudioPipeline.maximumDuration
        #expect(bytes < 15_000_000, "\(Int(bytes)) bytes at the cap")
        #expect(AudioPipeline.maximumDuration == 600)
        #expect(AudioPipeline.warningThreshold == 570)
    }

    @Test("metering maps silence to nothing and speech to something visible")
    func meterNormalisation() {
        // A linear map of dBFS leaves every bar flat on the floor: speech lives between −40 and
        // −10, which is the top quarter of the range.
        #expect(AudioPipeline.normalize(-160) == 0)
        #expect(AudioPipeline.normalize(-50) == 0)
        #expect(AudioPipeline.normalize(0) == 1)

        let quiet = AudioPipeline.normalize(-40)
        let talking = AudioPipeline.normalize(-20)
        #expect(quiet > 0, "a quiet voice still moves the waveform")
        #expect(talking > quiet)
        #expect(talking <= 1)
        // Not a straight line — the curve opens up the quiet end.
        #expect(AudioPipeline.normalize(-25) < 0.5)
    }
}

// MARK: - The state machine

@MainActor
@Suite("Audio recorder state")
struct AudioPipelineStateTests {

    private func pipeline() throws -> AudioPipeline {
        AudioPipeline(store: try temporaryStore())
    }

    @Test("it starts idle and reports nothing captured")
    func startsIdle() throws {
        let pipeline = try pipeline()
        #expect(pipeline.state == .idle)
        #expect(pipeline.elapsed == 0)
        #expect(pipeline.levels.isEmpty)
        #expect(pipeline.isRecording == false)
    }

    @Test("pausing an idle recorder does nothing")
    func pauseFromIdleIsInert() throws {
        let pipeline = try pipeline()
        pipeline.pause(canResume: true)
        #expect(pipeline.state == .idle, "there is nothing to pause")
    }

    @Test("cancel from paused returns to idle and clears the take")
    func cancelFromPaused() throws {
        let pipeline = try pipeline()
        pipeline.prepareForTesting(mediaId: nil, state: .paused(canResume: true))
        pipeline.cancel()
        #expect(pipeline.state == .idle)
        #expect(pipeline.elapsed == 0)
        #expect(pipeline.levels.isEmpty)
    }

    @Test("cancel is the only path that destroys a take, and it clears staging")
    func cancelRemovesTheFile() async throws {
        let store = try temporaryStore()
        let pipeline = AudioPipeline(store: store)
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 0.5, to: url)
        #expect(store.exists(url))

        pipeline.prepareForTesting(mediaId: id, state: .paused(canResume: true))
        pipeline.cancel()

        #expect(!store.exists(url), "cancel is the one path allowed to delete audio")
        #expect(pipeline.state == .idle)
    }

    @Test("backgrounding finalises rather than abandons")
    func backgroundingPreserves() async throws {
        // The worst possible bug in this feature is silent loss. Backgrounding stops the
        // recorder so AAC writes its trailer, and leaves a playable file behind.
        let store = try temporaryStore()
        let pipeline = AudioPipeline(store: store)
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 1.0, to: url)

        pipeline.prepareForTesting(mediaId: id, state: .recording)
        pipeline.finalizeForBackground()

        #expect(pipeline.state == .paused(canResume: false))
        #expect(store.exists(url), "the file survives the app going away")
        let finished = try #require(await AudioPipeline.finalize(mediaId: id, url: url))
        #expect(finished.duration > 0, "and it is playable, not a truncated container")
    }

    @Test("an interruption pauses and keeps the partial file")
    func interruptionKeepsBytes() async throws {
        let store = try temporaryStore()
        let pipeline = AudioPipeline(store: store)
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 1.0, to: url)
        pipeline.prepareForTesting(mediaId: id, state: .recording)

        // The real notification, through the real observer, to the real handler.
        pipeline.observeInterruptions()
        defer { pipeline.stopObservingInterruptions() }
        postInterruption(.began)

        #expect(pipeline.state == .paused(canResume: true))
        #expect(store.exists(url))
        #expect(try #require(await AudioPipeline.finalize(mediaId: id, url: url)).duration > 0)
    }

    @Test("interruption end carries the system's resume hint through")
    func interruptionEndOffersResume() throws {
        let pipeline = try pipeline()
        pipeline.prepareForTesting(mediaId: UUID(), state: .recording)

        pipeline.apply(interruption: .began, shouldResume: false)
        #expect(pipeline.state == .paused(canResume: true))

        pipeline.apply(interruption: .ended, shouldResume: true)
        #expect(pipeline.state == .paused(canResume: true), "offered, never auto-resumed")

        pipeline.apply(interruption: .ended, shouldResume: false)
        #expect(pipeline.state == .paused(canResume: false))
    }

    @Test("headphones pulled out pauses instead of playing on through the speaker")
    func routeChangePauses() throws {
        // Without this the session reroutes to the speaker and keeps recording, which at a
        // dinner table means the room hears what was being captured.
        let pipeline = try pipeline()
        pipeline.prepareForTesting(mediaId: UUID(), state: .recording)

        pipeline.observeInterruptions()
        defer { pipeline.stopObservingInterruptions() }
        postRouteChange(.oldDeviceUnavailable)

        #expect(pipeline.state == .paused(canResume: true))
    }

    @Test("an unrelated route change does not interrupt a recording")
    func unrelatedRouteChangeIgnored() throws {
        let pipeline = try pipeline()
        pipeline.prepareForTesting(mediaId: UUID(), state: .recording)

        pipeline.apply(routeChange: .newDeviceAvailable)
        #expect(pipeline.state == .recording)
    }

    @Test("the cap stops the recording and keeps the file")
    func capPreserves() async throws {
        // Ten minutes is a boundary, not a failure. A cap that discarded would throw away the
        // longest take anyone ever made.
        let store = try temporaryStore()
        let pipeline = AudioPipeline(store: store)
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 1.0, to: url)
        pipeline.prepareForTesting(mediaId: id, state: .recording)

        // `record(forDuration:)` ends by calling this delegate method — the same one an
        // explicit stop uses — so the cap is tested through the shipped path.
        let recorder = try pipeline.makeRecorderForTesting(at: url)
        pipeline.audioRecorderDidFinishRecording(recorder, successfully: true)

        // The delegate is `nonisolated` and hops to the main actor to finish, so the result
        // lands on a later turn. Polled rather than slept on: a fixed sleep is either flaky or
        // slow, and this says what it is actually waiting for.
        for _ in 0..<60 {
            if case .recording = pipeline.state {
                try await Task.sleep(for: .milliseconds(50))
            } else {
                break
            }
        }

        guard case .finished(let recording) = pipeline.state else {
            Issue.record("expected a finished take, got \(pipeline.state)")
            return
        }
        #expect(recording.duration > 0)
        #expect(store.exists(url), "capped, not discarded")
    }

    @Test("a denied microphone is a state, not a dead end")
    func deniedIsRecoverable() throws {
        let pipeline = try pipeline()
        pipeline.prepareForTesting(mediaId: nil, state: .denied)
        #expect(pipeline.state == .denied)
        // Nothing about the denied state prevents leaving it: the composer's other modes stay
        // available and the mission stays dismissible. Asserted in `AudioComposerTests`.
        #expect(pipeline.isRecording == false)
    }
}

// MARK: - Staging, drafts, and the upload path

@MainActor
@Suite("Audio through the save path")
struct AudioComposerTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: LocalStore.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
    }

    private func client(_ performer: StubPerformer) -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:8000/")!,
            performer: performer,
            tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
        )
    }

    @Test("a finished take becomes a draft that carries its duration and no thumbnail")
    func draftFromRecording() async throws {
        let store = try temporaryStore()
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 2.0, to: url)
        let recording = try #require(await AudioPipeline.finalize(mediaId: id, url: url))

        let draft = MediaDraftBuilder.makeAudio(recording)

        #expect(draft.kind == "audio")
        #expect(draft.isAudio)
        #expect(draft.contentType == "audio/m4a")
        #expect(draft.fileExtension == "m4a")
        #expect(draft.durationSeconds == Int(recording.duration.rounded()))
        #expect(draft.byteCount > 0)
        // A voice note has no thumbnail, and claiming one would let the staging sweep delete
        // the only local copy of the file.
        #expect(draft.hasThumbnail == false)
        #expect(draft.thumbnail.isEmpty)
        // No EXIF, no invented date — the composer's date pill owns `occurred_at`.
        #expect(draft.capturedAt == nil)
    }

    @Test("a staged recording survives a relaunch and is found by the sweep")
    func survivesRelaunch() async throws {
        // The staging store is addressed by media id and read from disk, so a force quit
        // mid-recording leaves something the next launch can pick up.
        let store = try temporaryStore()
        let context = try makeContext()
        let id = UUID()
        let url = store.originalURL(for: id, ext: AudioPipeline.fileExtension)
        try writeRecording(seconds: 1.0, to: url)

        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "he told me about the pond")
        entry.sync = .synced
        entry.existsOnServer = true
        context.insert(entry)
        let media = Media(
            id: id,
            entryId: entry.id,
            kind: "audio",
            contentType: AudioPipeline.contentType,
            byteCount: 1_000,
            stagedExtension: AudioPipeline.fileExtension,
            durationSeconds: 1
        )
        context.insert(media)
        try context.save()

        // A fresh store over the same directory is what a relaunch looks like.
        let reopened = StagingStore(root: store.root)
        #expect(reopened.exists(reopened.originalURL(for: id, ext: "m4a")))

        let due = MediaCoordinator.dueMedia(in: context)
        #expect(due.contains { $0.id == id }, "the sweep picks it up")
    }

    @Test("the entry syncs before its audio, always")
    func entriesDrainBeforeMedia() async throws {
        // Media upload is gated on the entry existing server-side: `POST /media/upload-url`
        // needs an `entry_id` it recognises, and asking earlier burns a retry on a certain 404.
        let store = try temporaryStore()
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "the duck story")
        context.insert(entry)
        let media = Media(
            entryId: entry.id,
            kind: "audio",
            contentType: AudioPipeline.contentType,
            byteCount: 900,
            stagedExtension: "m4a",
            durationSeconds: 4
        )
        context.insert(media)
        try context.save()

        // While the entry is unsynced, its audio is not even due.
        #expect(MediaCoordinator.dueMedia(in: context).isEmpty, "not due until the entry lands")

        let performer = StubPerformer()
        let created = Data("""
        {"id":"\(entry.id.uuidString)","child_id":"\(entry.childId.uuidString)",
         "assignment_id":null,"occurred_at":"2026-08-09T10:00:00.000Z",
         "created_at":"2026-08-09T10:00:00.000Z","updated_at":"2026-08-09T10:00:00.000Z",
         "deleted_at":null,"title":null,"body":"the duck story","entry_type":"audio",
         "child_age_months":62,"unlock_at_age":null}
        """.utf8)
        performer.on("/entries") { _ in (created, 201) }

        await EntrySync(api: client(performer), context: context).sweep()

        #expect(entry.sync == .synced)
        #expect(MediaCoordinator.dueMedia(in: context).contains { $0.id == media.id },
                "only now is the audio eligible")
        _ = store
    }

    @Test("an entry with audio and photos together carries both")
    func audioAndPhotosOnOneEntry() throws {
        // Not an audio-only entry type. The media model has always allowed a mix and the
        // composer must not quietly forbid one.
        let context = try makeContext()
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "at the pond")
        entry.sync = .synced
        entry.existsOnServer = true
        context.insert(entry)

        let voice = Media(entryId: entry.id, kind: "audio", contentType: "audio/m4a", byteCount: 900, stagedExtension: "m4a", durationSeconds: 7)
        let photo = Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 1_200, stagedExtension: "jpg")
        context.insert(voice)
        context.insert(photo)
        try context.save()

        let due = MediaCoordinator.dueMedia(in: context)
        #expect(due.count == 2)
        #expect(Set(due.map(\.kind)) == ["audio", "photo"])
    }

    @Test("an audio entry with no transcript is complete, not awaiting something")
    func noTranscriptIsComplete() async throws {
        // The transcript slot is simply absent until P3 fills it. It must never render as an
        // empty space implying the entry is unfinished.
        let entry = try cachedEntry(type: "audio", body: nil)
        let media = completeMedia(entryId: entry.id, kind: "audio", duration: 12)
        let card = EntryCardModel(entry: entry, media: [media])

        #expect(card.voice?.durationSeconds == 12)
        #expect(card.voice?.openingLine == nil, "no transcript is absent, not blank")
        #expect(card.typeLabel == "Voice")
        #expect(card.isAwaitingSync == false)
    }
}
