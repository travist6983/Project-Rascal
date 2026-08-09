import AVFoundation
import Foundation

/// Recording a voice, and never losing one.
///
/// The decision, recorded in `docs/decisions.md`: **AAC in `.m4a`, 44.1 kHz, mono, 96 kbps.**
/// Mono because this is a voice archive and stereo doubles the storage for nothing — a child
/// talking is a point source. AAC in MP4 for the same reason photos are JPEG and video is
/// H.264: the archive has to open in 2040 in something that isn't Apple.
///
/// Ten minutes at those settings is roughly 7MB, comfortably under the server's multipart
/// threshold, so audio takes the ordinary single-PUT path. **Nothing here special-cases audio to
/// stay under that line.** A file that somehow exceeds it goes through the existing multipart
/// path unchanged, because the server decides which path applies from the byte count it is given.
///
/// The rule this type exists to keep: **recorded bytes are never lost.** Every interruption — a
/// call, Siri, headphones pulled out, the app backgrounded — finalises what has been captured so
/// far to a real file on disk. The only path that destroys audio is the user explicitly saying
/// so, and that path asks first.
@MainActor
@Observable
final class AudioPipeline: NSObject {

    // MARK: The format, in one place

    /// 44.1 kHz mono AAC at 96 kbps. Asserted against the *written file* in
    /// `AudioPipelineTests`, not against this dictionary — passing settings is not the same as
    /// producing them, and only the file is the archive.
    nonisolated static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    nonisolated static let fileExtension = "m4a"
    nonisolated static let contentType = "audio/m4a"

    /// Ten minutes. At the cap the recording **stops and is kept** — a cap that discarded would
    /// be a cap that loses the take someone just made.
    nonisolated static let maximumDuration: TimeInterval = 10 * 60
    /// Thirty seconds out, the elapsed time is emphasised. Quietly: it is a fact about the
    /// recording, not a countdown, and nothing about it turns red.
    nonisolated static let warningThreshold: TimeInterval = maximumDuration - 30

    // MARK: State

    /// Where the recorder is. The UI renders one of these and nothing else.
    enum State: Equatable {
        case idle
        case recording
        /// Interrupted — by a call, by Siri, by headphones being pulled. The partial file is on
        /// disk. `canResume` is false when the system told us not to offer it.
        case paused(canResume: Bool)
        /// Stopped with a file to listen to before committing.
        case finished(Recording)
        /// The microphone was refused. Calm, and never a dead end.
        case denied
        case failed(String)
    }

    /// A finished take.
    struct Recording: Equatable, Sendable {
        let mediaId: UUID
        let url: URL
        /// Read from the finished asset, never from the UI timer, which drifts over ten minutes.
        let duration: TimeInterval
        let byteCount: Int
    }

    private(set) var state: State = .idle
    /// Seconds captured so far, from the recorder rather than a wall clock, so a pause does not
    /// keep counting.
    private(set) var elapsed: TimeInterval = 0
    /// Newest last, 0…1, for the waveform. Bounded — see `meterHistoryLength`.
    private(set) var levels: [Float] = []

    var isRecording: Bool { state == .recording }
    var isAtWarning: Bool { elapsed >= Self.warningThreshold }

    // MARK: Machinery

    private let store: StagingStore
    private let session: AVAudioSession
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    /// The id is minted before the first byte, so the staged file has its final name immediately
    /// and a force quit mid-recording leaves something the sweep can identify.
    private var mediaId: UUID?

    /// About four seconds of history at the sample rate below — enough to read as a waveform,
    /// short enough that the array never grows without bound over ten minutes.
    nonisolated static let meterHistoryLength = 48
    nonisolated static let meterInterval: TimeInterval = 1.0 / 12.0

    init(store: StagingStore = StagingStore(), session: AVAudioSession = .sharedInstance()) {
        self.store = store
        self.session = session
        super.init()
    }

    // MARK: Permission

    /// `AVAudioApplication`, not `AVAudioSession.requestRecordPermission` — the latter is
    /// deprecated and would trip the zero-warning gate.
    static func permission() -> AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Ask, or report what was already decided. Returns whether recording may proceed.
    @discardableResult
    func requestPermission() async -> Bool {
        switch Self.permission() {
        case .granted:
            return true
        case .denied:
            state = .denied
            return false
        default:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { state = .denied }
            return granted
        }
    }

    // MARK: Recording

    /// Begin. Returns false if the microphone was refused, which leaves `state` at `.denied` and
    /// the caller free to offer the mission another way — a refusal must never trap anyone.
    @discardableResult
    func start() async -> Bool {
        guard await requestPermission() else { return false }
        guard state != .recording else { return true }

        let id = mediaId ?? UUID()
        mediaId = id
        let url = store.originalURL(for: id, ext: Self.fileExtension)

        do {
            try activateSession()
            try store.prepareForWriting(at: url)

            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            recorder.delegate = self
            // The waveform is driven from this. Without it `averagePower` returns 0 forever.
            recorder.isMeteringEnabled = true
            // The cap is handed to the recorder rather than policed by the timer: it stops the
            // file cleanly at the boundary even if the app is busy.
            guard recorder.record(forDuration: Self.maximumDuration) else {
                throw Failure.couldNotStart
            }

            self.recorder = recorder
            levels = []
            elapsed = 0
            state = .recording
            startMetering()
            return true
        } catch {
            state = .failed(Self.explain(error))
            return false
        }
    }

    /// Stop and keep. Produces a `Recording` with the duration read from the written asset.
    func stop() async {
        guard let recorder, let mediaId else { return }
        stopMetering()
        recorder.stop()
        self.recorder = nil
        deactivateSession()

        let url = recorder.url
        guard let finished = await Self.finalize(mediaId: mediaId, url: url) else {
            // The file is still on disk; only the reading of it failed. Said plainly rather than
            // pretending the take is gone.
            state = .failed("That recording saved, but its length couldn't be read.")
            return
        }
        elapsed = finished.duration
        state = .finished(finished)
    }

    /// Pause and keep what exists. Used by every interruption path.
    ///
    /// `AVAudioRecorder.pause()` leaves the file open and resumable; the bytes captured so far
    /// are already written. Nothing here discards.
    func pause(canResume: Bool) {
        guard state == .recording else { return }
        stopMetering()
        recorder?.pause()
        state = .paused(canResume: canResume)
    }

    /// Continue a paused take into the same file.
    func resume() {
        guard case .paused = state, let recorder else { return }
        do {
            try activateSession()
        } catch {
            state = .failed(Self.explain(error))
            return
        }
        guard recorder.record() else {
            state = .failed(Self.explain(Failure.couldNotStart))
            return
        }
        state = .recording
        startMetering()
    }

    /// The one path that destroys audio. The caller confirms first — see `AudioRecorderSheet`.
    func cancel() {
        stopMetering()
        recorder?.stop()
        recorder = nil
        deactivateSession()
        if let mediaId { store.removeAll(for: mediaId) }
        mediaId = nil
        elapsed = 0
        levels = []
        state = .idle
    }

    /// Throw away a finished take and start again. Same destruction, same rule: confirmed first.
    func discardAndReset() {
        cancel()
    }

    /// Finalise whatever exists without a user gesture — the app is going away.
    ///
    /// **This is the anti-data-loss path.** Backgrounding, termination, a crash of the enclosing
    /// screen: the recorder is stopped so AAC writes its trailer and the file on disk is a
    /// playable m4a rather than a truncated one. The staging store keeps it under the media id,
    /// so the next launch can find it.
    func finalizeForBackground() {
        guard state == .recording || isPaused else { return }
        stopMetering()
        recorder?.stop()
        recorder = nil
        deactivateSession()
        state = .paused(canResume: false)
    }

    private var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// Read the written file. Duration comes from the asset because the UI timer drifts, and a
    /// wrong `duration_seconds` is wrong in the archive forever.
    nonisolated static func finalize(mediaId: UUID, url: URL) async -> Recording? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return Recording(mediaId: mediaId, url: url, duration: seconds, byteCount: bytes ?? 0)
    }

    // MARK: Session

    /// `.playAndRecord` because the review step plays the take back without tearing the session
    /// down and rebuilding it. `.defaultToSpeaker` so a phone held normally is audible;
    /// `.allowBluetooth` so a paired headset works.
    private func activateSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            // `.allowBluetoothHFP`, not `.allowBluetooth` — the latter was renamed and now
            // warns, and a warning is a failed build here. Same capability, current spelling.
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true)
    }

    /// **Always paired with activation.** A session left active ducks the user's music
    /// indefinitely, which is the kind of bug someone notices an hour later in the car and never
    /// connects to this app.
    private func deactivateSession() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Metering

    private func startMetering() {
        stopMetering()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            // `owner` rather than reaching for the weak binding inside the hop: a capture-list
            // binding read from a nested concurrent closure counts as a captured var, which
            // Swift 6 rejects. An immutable local is the same weak reference and satisfies it.
            let owner = self
            Task { @MainActor in owner?.sample() }
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// One sample of the waveform, from the recorder's own meter.
    ///
    /// Deliberately **not** an `AVAudioEngine` tap. Metering is a documented one-liner, it is
    /// enough to draw a bar, and a tap would be a second audio graph to keep alive across every
    /// interruption path above for no visible gain.
    private func sample() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        levels.append(Self.normalize(recorder.averagePower(forChannel: 0)))
        if levels.count > Self.meterHistoryLength {
            levels.removeFirst(levels.count - Self.meterHistoryLength)
        }
    }

    /// dBFS → 0…1, on a curve rather than linearly.
    ///
    /// `averagePower` is decibels: −160 is silence and 0 is clipping, and speech spends most of
    /// its time between −40 and −10. A linear map of that range leaves the bars flat against the
    /// floor; the exponent opens up the quiet end so a voice actually moves the waveform.
    nonisolated static func normalize(_ decibels: Float) -> Float {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        guard decibels > floor else { return 0 }
        let clamped = min(decibels, 0)
        return powf((clamped - floor) / -floor, 1.6)
    }

    // MARK: Interruptions

    /// Wire the notifications this pipeline reacts to. Called by the recorder screen when it
    /// appears, torn down when it leaves.
    ///
    /// Every one of these ends in a preserved file. None of them discards.
    func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    func stopObservingInterruptions() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: session)
    }

    /// A call, Siri, a timer going off.
    ///
    /// On `.ended` the system may say the app *should* resume. Even then this only moves to a
    /// resumable paused state — **it never restarts recording on its own.** A microphone that
    /// turns itself back on after a phone call, with no one looking at the screen, is not a thing
    /// this app is going to do.
    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
            .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        apply(interruption: type, shouldResume: options.contains(.shouldResume))
    }

    /// The decision, separated from parsing the notification that carried it.
    func apply(interruption type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            pause(canResume: true)
        case .ended:
            if case .paused = state {
                state = .paused(canResume: shouldResume)
            }
        @unknown default:
            pause(canResume: false)
        }
    }

    /// Headphones pulled out mid-sentence.
    ///
    /// Without this the session reroutes to the speaker and carries on recording — which at a
    /// dinner table means the room hears what was being recorded. Pause, and let the person
    /// decide.
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }
        apply(routeChange: reason)
    }

    /// The decision, separated from parsing the notification that carried it.
    func apply(routeChange reason: AVAudioSession.RouteChangeReason) {
        if reason == .oldDeviceUnavailable {
            pause(canResume: true)
        }
    }

    // MARK: Test seam

    #if DEBUG
    /// Put the pipeline where a microphone would have put it.
    ///
    /// **The simulator has no microphone**, so `.recording` is unreachable by the real path and
    /// there is no way to test pause, resume, cancel, backgrounding or the cap without this.
    /// It is deliberately the whole of the seam: every transition exercised afterwards runs the
    /// shipped code, and it is compiled out of a release build entirely.
    func prepareForTesting(mediaId: UUID?, state: State) {
        self.mediaId = mediaId
        self.state = state
    }

    /// The recorder object the cap and the delegate need. Constructing one requires no
    /// microphone; only `record()` would.
    func makeRecorderForTesting(at url: URL) throws -> AVAudioRecorder {
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.delegate = self
        self.recorder = recorder
        return recorder
    }
    #endif

    // MARK: Errors

    enum Failure: Error, Equatable {
        case couldNotStart
    }

    nonisolated static func explain(_ error: Error) -> String {
        if let failure = error as? Failure, failure == .couldNotStart {
            return "The microphone didn't start. Try again in a moment."
        }
        return "Recording couldn't start: \(error.localizedDescription)"
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioPipeline: AVAudioRecorderDelegate {

    /// Fires on the ten-minute cap as well as on an explicit stop, because `record(forDuration:)`
    /// ends the same way either one does. The file is kept in both cases — a cap that discarded
    /// would throw away the longest take someone ever made.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in
            guard self.state == .recording, let mediaId = self.mediaId else { return }
            self.stopMetering()
            self.recorder = nil
            self.deactivateSession()
            guard flag, let finished = await Self.finalize(mediaId: mediaId, url: url) else {
                self.state = .failed("That recording stopped early. What was captured is saved.")
                return
            }
            self.elapsed = finished.duration
            self.state = .finished(finished)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.stopMetering()
            self.recorder = nil
            self.deactivateSession()
            // The file up to this point is still on disk and still playable.
            self.state = .paused(canResume: false)
        }
    }
}
