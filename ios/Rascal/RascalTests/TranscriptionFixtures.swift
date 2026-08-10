import Foundation
import SwiftData
import Testing

@testable import Rascal

// **A wall clock cannot order two concurrent operations, and neither can a poll loop.**
//
// The cancellation tests used to sleep 60ms and assume the run was under way by then. That holds
// on a fast, idle machine and stops holding on a loaded CI runner, which is how this suite went
// red on a branch that changed nothing about transcription.
//
// Polling was tried as the replacement and was worse: waking the main actor every 2ms for ten
// seconds starves the very MainActor task the test is waiting to start, so it timed out under a
// full-suite run that the original sleep survived. The poll was competing with its own subject.
//
// A continuation handshake was tried next and hung outright: it still needed the detached
// `Task { await runBacklog() }` to be scheduled, and under a full-suite run it was not.
//
// So the run is no longer detached at all. The test awaits `runBacklog()` directly — its own task
// *is* the run — and `onEnter` fires from inside `transcribe` at the row the test names. The only
// asynchrony left is a hop back to the main actor to call `cancelBacklog`, and that happens while
// the stub is parked in a delay measured in whole seconds.

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

    /// Read from the test while `transcribe` may be appending on another executor, so both sides
    /// go through the lock. The stored properties are private and the readers are computed —
    /// a `private(set)` array would have let a test read it unsynchronised, which is a data race
    /// however unlikely it is to be caught.
    private var requestedValues: [URL] = []
    private var peakConcurrencyValue = 0
    private var inFlight = 0

    var requested: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requestedValues
    }

    /// The signal a test waits on to know a run is genuinely inside the transcriber. Recorded
    /// before the stub's delay begins, so seeing it means the run is parked mid-inference and
    /// cancellation has something real to interrupt.
    var requestedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requestedValues.count
    }

    /// The highest number of `transcribe` calls in flight at once. **One is the assertion.**
    var peakConcurrency: Int {
        lock.lock(); defer { lock.unlock() }
        return peakConcurrencyValue
    }

    /// Called from inside `transcribe`, before the delay, with the number of entries so far.
    ///
    /// **This is how the cancellation tests stop a run: from within the run.** Every other
    /// approach tried here coordinated two tasks and depended on the scheduler to interleave
    /// them, which is the thing that does not hold under load. The hook fires on the run's own
    /// thread at a point the test chose, so there is nothing to race.
    private var onEnterHook: (@Sendable (Int) -> Void)?

    func onEnter(_ hook: @escaping @Sendable (Int) -> Void) {
        lock.lock(); defer { lock.unlock() }
        onEnterHook = hook
    }

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

    /// Reads the stored array, **not** the `requested` accessor.
    ///
    /// `requested` takes the same lock, and `NSLock` is not reentrant — going through it from
    /// here deadlocks the moment anything asks for a call count. That is what happens when a
    /// stored `private(set)` property is turned into a locked accessor and one caller is missed.
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requestedValues.count
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
        lock.lock()
        requestedValues.append(url)
        inFlight += 1
        peakConcurrencyValue = max(peakConcurrencyValue, inFlight)
        let reached = requestedValues.count
        let hook = onEnterHook
        let pause = delay
        lock.unlock()

        // Called outside the lock. The hook runs arbitrary test code, and doing that while
        // holding a lock this class takes on every call is how a suite deadlocks instead of
        // failing.
        hook?(reached)
        return pause
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
