import Foundation
import SwiftData

@testable import Rascal

/// The stub behind `SpeechTranscribing`, and the scaffolding the transcription suites share.
///
/// **`SpeechAnalyzer` cannot run here and it never will.** It is iOS 26 only, `isAvailable` is
/// false on every simulator, and the model assets are a multi-hundred-megabyte download no CI
/// runner has. That is the whole reason the seam exists — without it, every rule worth having
/// (local write before push, backoff, do-not-clobber-on-pull, render nothing when there is
/// nothing) would be unverifiable, which is to say unverified.
///
/// So: everything below the seam is asserted against this, and nothing below it is asserted at
/// all. `docs/device-verification-transcription.md` is where the other half is checked.
final class StubTranscriber: SpeechTranscribing, @unchecked Sendable {
    private let lock = NSLock()

    private var readinessValue: TranscriptionReadiness
    private var outcome: Result<String, any Error>
    /// Held open so a test can arrive in the middle of a run — for cancellation, and for proving
    /// that two runs never overlap.
    private var delay: Duration = .zero

    private(set) var requested: [URL] = []
    /// The highest number of `transcribe` calls in flight at once. **One is the assertion.**
    private(set) var peakConcurrency = 0
    private var inFlight = 0

    init(
        readiness: TranscriptionReadiness = .ready(
            TranscriptionLocale(locale: Locale(identifier: "en-US"), isFallback: false)
        ),
        text: String = "and then the brachiosaurus ate the whole entire tree"
    ) {
        self.readinessValue = readiness
        self.outcome = .success(text)
    }

    // MARK: Driving it

    func set(readiness: TranscriptionReadiness) {
        lock.lock(); defer { lock.unlock() }
        readinessValue = readiness
    }

    func set(text: String) {
        lock.lock(); defer { lock.unlock() }
        outcome = .success(text)
    }

    func set(failure: any Error) {
        lock.lock(); defer { lock.unlock() }
        outcome = .failure(failure)
    }

    func set(delay: Duration) {
        lock.lock(); defer { lock.unlock() }
        self.delay = delay
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requested.count
    }

    // MARK: SpeechTranscribing

    func readiness(preferring preferred: Locale) async -> TranscriptionReadiness {
        // Locking is confined to a synchronous helper, exactly as `StubPerformer` does it. Taking
        // a lock directly in an `async` function is a shape the compiler rejects in Swift 6
        // whether or not this particular body holds it across a suspension.
        currentReadiness()
    }

    private func currentReadiness() -> TranscriptionReadiness {
        lock.lock(); defer { lock.unlock() }
        return readinessValue
    }

    func transcribe(fileURL: URL, in locale: TranscriptionLocale) async throws -> String {
        let pause = enter(fileURL)
        defer { leave() }

        if pause > .zero {
            // `Task.sleep` throws `CancellationError`, which is exactly the shape the real
            // analyzer's cancellation takes — so a cancelled stub run and a cancelled real one
            // leave the caller in the same place.
            try await Task.sleep(for: pause)
        }
        try Task.checkCancellation()
        return try result()
    }

    /// Synchronous on purpose: nothing is held across a suspension, and taking a lock directly
    /// in an `async` function is a shape the compiler objects to whether or not it is safe.
    private func enter(_ url: URL) -> Duration {
        lock.lock(); defer { lock.unlock() }
        requested.append(url)
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        return delay
    }

    private func leave() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }

    private func result() throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try outcome.get()
    }
}

// MARK: - Server shapes

/// `MediaDerivedResponse` — the updated `MediaOut`, plus every tag on the entry afterwards.
func derivedJSON(
    mediaId: UUID,
    entryId: UUID,
    transcript: String,
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_500)
) -> Data {
    Data("""
    {"media":\(syncMediaJSON(
        id: mediaId, entryId: entryId, kind: "audio", status: "complete",
        transcript: transcript, updatedAt: updatedAt
    )),"tags":[]}
    """.utf8)
}

// MARK: - Local shapes

/// A completed voice note with its recording still on disk.
///
/// The file is real and the staging root is a fresh temporary directory, so nothing here touches
/// the simulator's Application Support. Its **contents are never read** — the stub transcriber
/// only records the URL it was handed — but it has to exist, because `resolveInput` checks.
@MainActor
func stagedVoiceNote(
    entryId: UUID,
    in context: ModelContext,
    store: StagingStore,
    duration: Int = 42,
    transcriptState: TranscriptSync = .none,
    transcript: String? = nil
) -> Media {
    let media = Media(
        entryId: entryId,
        kind: "audio",
        contentType: AudioPipeline.contentType,
        byteCount: 96_000,
        stagedExtension: AudioPipeline.fileExtension,
        durationSeconds: duration
    )
    media.state = .complete
    media.transcript = transcript
    media.transcriptSync = transcriptState
    context.insert(media)

    let url = store.originalURL(for: media.id, ext: AudioPipeline.fileExtension)
    FileManager.default.createFile(atPath: url.path, contents: Data("not really audio".utf8))
    try? context.save()
    return media
}

/// A staging store rooted somewhere disposable, so two suites never share a directory.
func temporaryStagingStore() -> StagingStore {
    StagingStore(
        root: FileManager.default.temporaryDirectory
            .appending(path: "rascal-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    )
}

@MainActor
func inMemoryContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: LocalStore.schema,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
}

func testClient(_ performer: StubPerformer) -> APIClient {
    APIClient(
        baseURL: URL(string: "http://localhost:8000/")!,
        performer: performer,
        tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
    )
}
