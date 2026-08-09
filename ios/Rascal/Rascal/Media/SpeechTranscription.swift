import AVFoundation
import Foundation
import OSLog
import Speech

/// The real transcriber: `SpeechAnalyzer` and `SpeechTranscriber`, on device, offline, free.
///
/// Built alongside `VideoPipeline` and `AudioPipeline` and following their shape — a narrow type
/// that owns one format decision, states it in the doc comment, and throws a typed failure the
/// caller can record.
///
/// ## Availability is the first thing this type does, not the last
///
/// **Four** separate things have to be true before a single sample is read, and the first of them
/// is the one that is false on most phones this app runs on:
///
/// 1. **iOS 26.** The app's deployment target is 18.6 and `SpeechAnalyzer` is iOS 26 — so on a
///    large fraction of installs this framework does not exist at all. That is not a degenerate
///    case to handle later; it is the majority case today, and it is why every entry point here
///    opens with `#available` rather than assuming the import succeeded.
/// 2. The framework reports itself available on this device (`isAvailable`).
/// 3. A model for a usable locale is **installed**, not merely supported.
/// 4. The file is openable.
///
/// Any of them failing is a silent no-op. A device that cannot transcribe must produce an app that
/// behaves exactly as it did before this feature existed — no error, no banner, no empty
/// Transcript heading, nothing on a card that was not there yesterday.
///
/// An actor for one reason: `installationRequested`. Asking the system to download a model is a
/// once-per-process act, and the check-then-set that enforces it must not interleave.
actor SpeechTranscription: SpeechTranscribing {

    private static let log = Logger(subsystem: "app.rascal", category: "transcription")

    /// The asset download is requested at most once per process, and never awaited by anything a
    /// parent is waiting on. A device that has just been asked to fetch a model reports
    /// `installing`, the row stays queued, and a later run finds it installed.
    private var installationRequested = false

    /// Locales already reserved this process.
    ///
    /// Reserving is what keeps a model allocated to this app while it runs, and it is a per-locale
    /// fact that does not change underneath us — so doing it once beats doing it three hundred
    /// times during a backlog run, which is three hundred XPC round trips to be told the same
    /// thing. `AssetInventory.maximumReservedLocales` is small, and this app only ever wants one.
    private var reserved: Set<String> = []

    // MARK: - Availability

    func readiness(preferring preferred: Locale) async -> TranscriptionReadiness {
        // Below iOS 26 there is no `SpeechAnalyzer` to ask. Nothing is logged and nothing is
        // recorded on any row: this is not a failure, it is a phone.
        guard #available(iOS 26.0, *) else { return .unavailable }

        // The cheapest remaining check, and the one that is false on every simulator and every CI
        // runner. Everything below it costs an XPC round trip.
        guard SpeechTranscriber.isAvailable else { return .unavailable }

        // Both lists are gathered before anything is decided, so the decision itself is a pure
        // function that a test can drive — see `decide`. `supportedLocales` is only actually
        // needed on the miss, but reading it unconditionally is one round trip against a
        // once-per-sweep call, and it is what keeps the ladder out of the I/O.
        let installed = await SpeechTranscriber.installedLocales
        let supported = await SpeechTranscriber.supportedLocales

        let verdict = Self.decide(preferred: preferred, installed: installed, supported: supported)
        if case .installing(let locale) = verdict {
            await requestInstallationOnce(for: locale)
            return .installing
        }
        return verdict.readiness
    }

    /// The ladder, with the I/O taken out of it.
    ///
    /// Three outcomes and the order between them is the whole content: **installed beats
    /// supported**, because a model that merely *could* be downloaded transcribes nothing today,
    /// and supported-but-absent beats unsupported because the first resolves itself and the second
    /// never will. Getting that order wrong would either transcribe with a model that is not there
    /// or give up on a phone that was one download away.
    ///
    /// Extracted so it can be asserted rather than reasoned about. Everything it consumes is a
    /// plain value, so the suite drives it directly even though nothing around it can run.
    nonisolated static func decide(
        preferred: Locale,
        installed: [Locale],
        supported: [Locale]
    ) -> Verdict {
        if let resolved = TranscriptionLocale.resolve(preferred: preferred, installed: installed) {
            return .ready(resolved)
        }
        guard let wanted = TranscriptionLocale.resolve(preferred: preferred, installed: supported) else {
            return .unavailable
        }
        return .installing(wanted.locale)
    }

    /// `TranscriptionReadiness` plus the one thing it deliberately does not carry: *which* locale
    /// to ask the system to download. That is an instruction to this type, not a fact the queue
    /// has any use for.
    nonisolated enum Verdict: Equatable, Sendable {
        case ready(TranscriptionLocale)
        case installing(Locale)
        case unavailable

        var readiness: TranscriptionReadiness {
            switch self {
            case .ready(let locale): .ready(locale)
            case .installing: .installing
            case .unavailable: .unavailable
            }
        }
    }

    /// Ask the system for the model, once, and do not wait on it.
    ///
    /// `downloadAndInstall()` runs detached on purpose. It is a large download over a network the
    /// app does not control, and the caller of `readiness` is on a path that must return promptly
    /// — an upload finishing, or a sweep on foreground. Blocking either of them on a model
    /// download would turn a silent optional feature into a visible stall.
    @available(iOS 26.0, *)
    private func requestInstallationOnce(for locale: Locale) async {
        guard !installationRequested else { return }
        installationRequested = true

        let transcriber = SpeechTranscriber(locale: locale, preset: Self.preset)
        // `try?` over a throwing call that already returns an optional flattens to one optional:
        // no request needed, or none obtainable, are the same nothing-to-do here.
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        else { return }

        Self.log.notice("requesting speech model for \(locale.identifier, privacy: .public)")
        Task.detached(priority: .background) {
            do {
                try await request.downloadAndInstall()
            } catch {
                // Nothing to tell anyone. The next run asks again from scratch and finds either
                // an installed model or the same absence.
                Self.log.notice("speech model install did not finish: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Transcribing

    /// Plain transcription: no alternatives, no volatile partials, no timestamps.
    ///
    /// Only the text is persisted, because only the text is in the schema. Segment structure would
    /// be a migration, and `PATCH /media/{id}/derived` takes a string.
    @available(iOS 26.0, *)
    private static var preset: SpeechTranscriber.Preset { .transcription }

    func transcribe(fileURL: URL, in locale: TranscriptionLocale) async throws -> String {
        guard #available(iOS 26.0, *) else {
            // Unreachable through the queue, which checks `readiness` first — and implemented
            // rather than trapped, because "unreachable" is a claim about today's callers.
            throw TranscriptionFailure.engine("This phone's system is older than on-device transcription.")
        }
        guard let audio = try? AVAudioFile(forReading: fileURL) else {
            throw TranscriptionFailure.bytesUnreachable
        }

        // Reserving is what keeps the model allocated to this app while it runs. Once per locale
        // per process — see `reserved`. A failure is not fatal on its own, so the analyzer is
        // still given its chance to say whether it can actually work; the locale is only recorded
        // as reserved when the call actually succeeded.
        if !reserved.contains(locale.locale.identifier),
           (try? await AssetInventory.reserve(locale: locale.locale)) != nil {
            reserved.insert(locale.locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: locale.locale, preset: Self.preset)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // The collector starts **before** analysis does. `results` is a live sequence, not a
        // buffer that can be drained afterwards, so a collector started second is a collector that
        // misses the beginning of what was said.
        async let collected = Self.collect(transcriber.results)

        do {
            _ = try await analyzer.analyzeSequence(from: audio)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Stop the collector before leaving, or it waits on a sequence nobody will finish.
            await analyzer.cancelAndFinishNow()
            _ = try? await collected
            throw TranscriptionFailure.engine(error.localizedDescription)
        }

        // **Cancellation is checked after the analyzer has been shut down, not before.** Throwing
        // out from under a running analyzer is how one gets leaked. Either way nothing has been
        // written yet, which is the property that actually matters — a cancelled run leaves no
        // partial transcript because the write happens strictly after this returns.
        let text: String
        do {
            text = try await collected
        } catch is CancellationError {
            // Rethrown bare, because the queue matches on this type to distinguish "stopped" from
            // "failed" — a cancelled run records no attempt and no failure message.
            throw CancellationError()
        } catch {
            // Anything else out of the results sequence is an engine failure like any other. It
            // used to escape as a raw `Speech` error and land in the row's failure text as an
            // opaque domain string, which is not a sentence anyone should read in Settings.
            throw TranscriptionFailure.engine(error.localizedDescription)
        }
        try Task.checkCancellation()
        return Self.tidy(text)
    }

    /// Accumulate the finalised segments into one string.
    ///
    /// `isFinal` is checked even though `.transcription` asks for no volatile results: the option
    /// set decides what is *reported*, and folding a volatile segment into a permanent archive
    /// because the preset happened to change is not a mistake worth leaving available.
    @available(iOS 26.0, *)
    private static func collect(
        _ results: some AsyncSequence<SpeechTranscriber.Result, any Error> & Sendable
    ) async throws -> String {
        var pieces: [String] = []
        for try await result in results where result.isFinal {
            pieces.append(String(result.text.characters))
        }
        return pieces.joined(separator: " ")
    }

    /// Collapse the whitespace the segment joins leave behind.
    ///
    /// Segments arrive carrying their own leading spaces, so joining them produces doubles. This
    /// is cosmetic and it is also permanent — the string written here is the string a parent reads
    /// in 2040 — so it is done once, here, rather than at each of the places that render it.
    static func tidy(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
