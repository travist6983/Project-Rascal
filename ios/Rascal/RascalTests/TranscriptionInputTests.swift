import AVFoundation
import Foundation
import SwiftData
import Testing

@testable import Rascal

/// The two assumptions transcription rests on that were **assumed rather than checked** when it
/// was written, and that a stub can never check for you.
///
/// Neither is about `SpeechAnalyzer`, which genuinely cannot run here. Both are about the plumbing
/// on either side of it: the file going in, and the two `ModelContext`s the trigger crosses. Both
/// were listed as things I was not confident about; a test is the only honest way to stop being
/// unsure.
@MainActor
@Suite("Transcription inputs")
struct TranscriptionInputTests {

    // MARK: The file going in

    /// **`AVAudioFile` opens what the recorder actually writes.**
    ///
    /// `SpeechTranscription` hands `AVAudioFile(forReading:)` a `.m4a` and treats a failure as
    /// `bytesUnreachable`. If AAC-in-MP4 were not readable that way, every transcription on every
    /// device would fail with a message about the file being unreachable — and the stub, which
    /// never opens anything, would go on passing.
    ///
    /// The fixture is written at **exactly `AudioPipeline.settings`**, which is what the archive
    /// stores: 44.1 kHz mono AAC at 96 kbps.
    @Test("the recorder's own m4a is readable by the API transcription reads it with")
    func avAudioFileOpensTheRecordersOutput() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcribe-input-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRecording(seconds: 0.5, to: url)

        let file = try AVAudioFile(forReading: url)

        // Frames exist, so the analyzer would have samples to read rather than an empty file.
        #expect(file.length > 0)
        // Decoded to PCM on the way out, which is what an analyzer consumes. The *stored* format
        // is the compressed one; `processingFormat` is the decode target.
        #expect(file.processingFormat.sampleRate == 44_100)
        #expect(file.processingFormat.channelCount == 1)
    }

    @Test("a file that is not audio is a reachability failure, not a crash")
    func nonAudioIsHandled() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "not-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data("not really audio".utf8))

        // The exact guard `SpeechTranscription.transcribe` opens with. A staging file truncated by
        // a force quit lands here, and it has to be one recorded failed attempt rather than a trap.
        #expect((try? AVAudioFile(forReading: url)) == nil)
    }

    // MARK: The readiness ladder

    // `SpeechTranscription.decide` is the ordering that says whether anything runs at all, and
    // getting it wrong is silent in both directions: transcribe with a model that is not there, or
    // give up on a phone that was one download away. The I/O around it cannot run here, so the
    // decision was lifted out of the I/O to be asserted directly.

    private let english = Locale(identifier: "en-US")
    private let spanish = Locale(identifier: "es-MX")

    @Test("an installed model for the device's own locale is ready, and is not a fallback")
    func installedIsReady() {
        let verdict = SpeechTranscription.decide(
            preferred: spanish, installed: [spanish, english], supported: [spanish, english]
        )
        #expect(verdict == .ready(TranscriptionLocale(locale: spanish, isFallback: false)))
    }

    @Test("installed beats supported — a model that could be downloaded transcribes nothing today")
    func installedBeatsSupported() {
        // English is installed, Spanish is merely supported. The device wants Spanish. Preferring
        // "supported" here would mean queueing a download and transcribing nothing, when there was
        // a usable model sitting on the phone the whole time.
        let verdict = SpeechTranscription.decide(
            preferred: spanish, installed: [english], supported: [spanish, english]
        )
        #expect(verdict == .ready(TranscriptionLocale(locale: english, isFallback: true)))
    }

    @Test("supported but not installed asks for the download, and names the locale to fetch")
    func supportedAsksForTheDownload() {
        let verdict = SpeechTranscription.decide(
            preferred: spanish, installed: [], supported: [spanish, english]
        )
        // The locale is carried on the verdict rather than on `TranscriptionReadiness`: it is an
        // instruction to the transcriber, and the queue has no use for it.
        #expect(verdict == .installing(spanish))
        #expect(verdict.readiness == .installing)
    }

    @Test("supported but not installed prefers en-US when the device's own locale is unsupported")
    func fallbackAppliesToTheDownloadToo() {
        let verdict = SpeechTranscription.decide(
            preferred: Locale(identifier: "cy-GB"), installed: [], supported: [english]
        )
        #expect(verdict == .installing(english))
    }

    @Test("nothing supported that could serve this device is unavailable, and stays that way")
    func nothingUsableIsUnavailable() {
        let verdict = SpeechTranscription.decide(
            preferred: Locale(identifier: "cy-GB"), installed: [spanish], supported: [spanish]
        )
        // Not `installing` — there is nothing to wait for. A row queued against this would wait
        // forever, and the phone must simply look like it did before the feature existed.
        #expect(verdict == .unavailable)
        #expect(verdict.readiness == .unavailable)
    }

    @Test("an empty device is unavailable rather than ready")
    func nothingAtAllIsUnavailable() {
        #expect(SpeechTranscription.decide(preferred: english, installed: [], supported: [])
            == .unavailable)
    }

    // MARK: The two contexts the trigger crosses

    /// A real on-disk store, because the question is about two contexts over one **store** and an
    /// in-memory one is not obviously the same thing. Same approach as `StoreMigrationTests`.
    private func onDisk() throws -> ModelContainer {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "rascal-ctx-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(url: directory.appending(path: "test.store"))
        )
    }

    /// **The exact topology the automatic trigger runs in.**
    ///
    /// `MediaCoordinator` builds a fresh `ModelContext(LocalStore.shared)` for every call and marks
    /// the upload `complete` in it. `TranscriptionQueue` holds the long-lived context from the
    /// SwiftUI environment. So `enqueue` reads a row through a *different* context from the one
    /// that just wrote it, and if that read came back stale the row would look incomplete, the
    /// guard would reject it, and **every new recording would silently never be transcribed** —
    /// with the backlog button as the only way to ever get a transcript.
    ///
    /// The second fetch is what makes this a real test. The reading context loads the row first,
    /// so the question is whether an already-registered object is refreshed, not whether a cold
    /// fetch works.
    @Test("a row completed in one context is seen as complete by the other")
    func aSaveInOneContextIsVisibleInAnother() throws {
        let container = try onDisk()
        let writing = ModelContext(container)
        let reading = ModelContext(container)

        let media = Media(
            entryId: UUID(), kind: "audio",
            contentType: AudioPipeline.contentType, byteCount: 96_000
        )
        writing.insert(media)
        try writing.save()

        let before = try reading.fetch(FetchDescriptor<Media>())
        #expect(before.count == 1)
        #expect(before.first?.isComplete == false)

        // The upload lands, in the coordinator's own context.
        media.state = .complete
        try writing.save()

        let after = try reading.fetch(FetchDescriptor<Media>())
        #expect(after.first?.isComplete == true)
        #expect(TranscriptionQueue.isTranscribable(try #require(after.first)))
    }

    /// The other direction, which is the one the sweep depends on: the queue writes a transcript
    /// and marks the row, and every other reader of the store has to see it.
    @Test("a transcript written in one context is visible to the other")
    func aTranscriptIsVisibleAcrossContexts() throws {
        let container = try onDisk()
        let writing = ModelContext(container)
        let reading = ModelContext(container)

        let media = Media(
            entryId: UUID(), kind: "audio",
            contentType: AudioPipeline.contentType, byteCount: 96_000
        )
        media.state = .complete
        writing.insert(media)
        try writing.save()
        _ = try reading.fetch(FetchDescriptor<Media>())

        media.recordTranscript(
            "he said hangaburger",
            locale: TranscriptionLocale(locale: Locale(identifier: "en-US"), isFallback: false)
        )
        try writing.save()

        let row = try #require(try reading.fetch(FetchDescriptor<Media>()).first)
        #expect(row.transcript == "he said hangaburger")
        // And the pull-conflict rule agrees from over here too, which is the property that
        // actually protects the words.
        #expect(row.hasUnpushedTranscript)
    }

    // MARK: What the queue hands the transcriber

    /// **In place, not a copy.** The brief is explicit that the staged original is read where it
    /// already is — no copying, no re-encoding — and nothing else in the suite checks the URL that
    /// actually gets handed over.
    @Test("a recording made on this phone is transcribed from its staged original")
    func theStagedOriginalIsReadInPlace() async throws {
        let context = try inMemoryContext()
        let store = temporaryStagingStore()
        let transcriber = StubTranscriber()
        let media = stagedVoiceNote(entryId: UUID(), in: context, store: store)
        let expected = store.originalURL(for: media.id, ext: AudioPipeline.fileExtension)

        let subject = TranscriptionQueue(
            api: testClient(StubPerformer()), context: context,
            transcriber: transcriber, store: store
        )
        await subject.enqueue(mediaId: media.id)
        await subject.sweep()

        #expect(transcriber.requested == [expected])
        // Still there afterwards. A voice note has no thumbnail, so `stagedOriginalIsDisposable`
        // is never true for one and the staging sweep leaves it alone — transcription must not be
        // the thing that removes it either.
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }
}
