import Foundation

/// The boundary between "what was said" and how this device works it out.
///
/// **This protocol is the only abstraction this feature adds.** The queue, the coordinator, the
/// writeback and the views are all concrete — they are testable because the thing underneath
/// them can be stubbed, not because each of them grew an interface. `SpeechTranscription` is the
/// shipped implementation and the stub in the suite is the other one; there is no third.
///
/// It exists because `SpeechAnalyzer` cannot be exercised in a simulator or in CI: the model
/// assets are a multi-hundred-megabyte download the runner does not have, and `isAvailable` is
/// false there. Without a seam here, every rule that matters — write local before push, retry
/// with backoff, do not clobber on pull, render nothing when there is nothing — would be
/// untestable, which is to say unverified.
nonisolated protocol SpeechTranscribing: Sendable {

    /// What this device can do **right now**, for a given preferred locale.
    ///
    /// Asked before every run rather than cached, because all three inputs move underneath the
    /// app: assets finish downloading, the user changes language, and a device under storage
    /// pressure can have a model evicted.
    func readiness(preferring preferred: Locale) async -> TranscriptionReadiness

    /// Transcribe a local audio or video file into plain text.
    ///
    /// Cooperatively cancellable. A cancelled run throws `CancellationError` and **returns no
    /// partial text at all** — a half transcript written into a permanent archive is worse than
    /// no transcript, because nothing downstream can tell the two apart.
    func transcribe(fileURL: URL, in locale: TranscriptionLocale) async throws -> String
}

/// The locale a transcript was produced in, and whether that was the one asked for.
///
/// A plain `Locale` would lose the second half, and the second half is the interesting one: a
/// transcript of English audio produced by a Spanish model is not a worse transcript, it is
/// nonsense, and the archive has no way to know unless the row says which model wrote it.
nonisolated struct TranscriptionLocale: Equatable, Sendable {
    let locale: Locale
    /// True when the device's own locale had no installed model and `en-US` was used instead.
    let isFallback: Bool

    /// **The fallback rule, in one place.** The device's locale wins whenever a model for it is
    /// installed. Only when it is not, and `en-US` is, does English stand in — and the row
    /// records that it did.
    ///
    /// The alternative was to fall back silently, and it is the wrong one twice over: a Spanish
    /// model fed English audio produces confident nonsense, and an archive cannot audit what it
    /// was not told. Falling back *only* to `en-US`, rather than to whatever happens to be
    /// installed, keeps the failure mode to one known case instead of an arbitrary one.
    static let fallback = Locale(identifier: "en-US")

    static func resolve(preferred: Locale, installed: [Locale]) -> TranscriptionLocale? {
        if installed.contains(where: { matches($0, preferred) }) {
            return TranscriptionLocale(locale: preferred, isFallback: false)
        }
        if let english = installed.first(where: { matches($0, fallback) }) {
            return TranscriptionLocale(locale: english, isFallback: true)
        }
        return nil
    }

    /// Language and region, ignoring everything else an identifier can carry.
    ///
    /// `Locale` equality is identifier equality, and the identifiers on both sides of this
    /// comparison are not written by the same hand: the device's is whatever the user's settings
    /// produced (`en_US@calendar=gregorian` and friends), and the installed list is Apple's.
    /// Comparing them raw makes an installed model invisible for reasons that have nothing to do
    /// with speech.
    private static func matches(_ a: Locale, _ b: Locale) -> Bool {
        guard let left = a.language.languageCode, let right = b.language.languageCode else {
            return false
        }
        guard left == right else { return false }
        // Region is compared only when both state one. A model listed as plain `es` should serve
        // a device set to `es_MX`; two models that both name a region must name the same one.
        guard let leftRegion = a.region, let rightRegion = b.region else { return true }
        return leftRegion == rightRegion
    }
}

/// Whether there is any point starting.
///
/// Three cases and not two, because "the model is downloading" is genuinely different from "this
/// device cannot do it": the first resolves on its own and the row should stay queued, the second
/// never does and the app must look exactly as it did before this feature existed.
nonisolated enum TranscriptionReadiness: Equatable, Sendable {
    /// Go. The locale is the one that will actually be used.
    case ready(TranscriptionLocale)
    /// Supported here, assets not installed. Installation has been requested at most once this
    /// process; nothing is blocked on it and the row stays queued for a later run.
    case installing
    /// Not this device, not this locale, not today. **Degrade silently** — no error, no banner,
    /// no "transcription unavailable" slot on a card.
    case unavailable
}

/// What went wrong, in the vocabulary the row records.
///
/// Every case is a sentence a parent could read, because `transcriptFailure` is shown in the
/// backlog row. None of them apologises and none of them is vague — `docs/design-system.md`,
/// copy rules.
nonisolated enum TranscriptionFailure: Error, Equatable {
    /// The file the row points at is not on this device and could not be fetched back.
    case bytesUnreachable
    /// The recording is only on the server, and this phone is on a network it pays for. A
    /// deferral rather than a failure — see `MediaAccess.backfillSession` for why bulk backfill
    /// refuses cellular — so the sentence says what will happen rather than what went wrong.
    case waitingForWiFi
    /// The analyzer refused or died mid-run.
    case engine(String)

    var message: String {
        switch self {
        case .bytesUnreachable: "The recording wasn't reachable from this phone."
        case .waitingForWiFi: "Waiting for Wi-Fi — this one is only on the server."
        case .engine(let detail): "Transcribing stopped: \(detail)"
        }
    }
}
