import AVFoundation
import Foundation

/// Getting a video ready for the transcriber — which usually means doing nothing at all.
///
/// **The phase was specified around a premise that turned out to be false, and this file is what
/// is left after checking it.** Story 6 and this phase's own first implementation assumed
/// `AVAudioFile(forReading:)` could not open an mp4, so a video's audio had to be exported to a
/// separate m4a first. A diagnostic in `VideoAudioTrackTests` says otherwise: handed a real
/// H.264 + AAC mp4, `AVAudioFile` opens it and reads **22050 frames at 44.1 kHz mono** — the exact
/// audio written into it. Core Audio reads the audio track out of an MPEG-4 container directly.
///
/// So the export was machinery for a problem that does not exist, and it is gone. What remains is
/// the part that is genuinely needed, which the premise had been hiding:
///
/// **1. A video with no audio track must not look like a broken download.** `AVAudioFile` fails to
/// open one, and `SpeechTranscription` turns that into `bytesUnreachable` — a row that would burn
/// its whole retry budget against a silent clip, six times, over hours. Silent clips are ordinary:
/// screen recordings, a covered mic, a moment trimmed to no sound.
///
/// **2. A very long video still wants capping**, and that is the one case where an export earns
/// its cost — see `maximumDuration`.
enum VideoAudioTrack {

    /// What the caller should do with this video.
    enum Plan: Equatable {
        /// Hand the video's own URL to the transcriber. **The common case**, and it costs nothing.
        case readDirectly
        /// Audio was exported to this URL because the source is longer than the cap. The caller
        /// owns the file and must remove it.
        case extracted(URL)
        /// No audio track. Nothing to transcribe and nothing to clean up.
        case silent
    }

    /// The longest stretch this will transcribe.
    ///
    /// **A cap rather than chunking**, and the reason is what the archive is for: these are a
    /// child's videos, not lecture recordings. Past ten minutes is a recital or a car journey
    /// somebody forgot to stop, and the first ten minutes is both the useful part and the part a
    /// phone can do without heating up in a pocket.
    ///
    /// Chunking was the alternative and costs more than it returns here: overlap handling so a
    /// word split across a boundary is not lost twice, a join that does not double a sentence, and
    /// a partial-failure story for chunk four of seven — for a case the library does not produce.
    static let maximumDuration = CMTime(seconds: 600, preferredTimescale: 600)

    /// Decide what to do, and export only if the cap requires it.
    static func plan(for source: URL, exportingTo destination: URL) async throws -> Plan {
        let asset = AVURLAsset(url: source)

        // **This check is the load-bearing part of the file.** Without it a silent clip reaches
        // `AVAudioFile`, fails to open, and is recorded as an unreachable recording.
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return .silent }

        let duration = try await asset.load(.duration)
        guard duration > maximumDuration else { return .readDirectly }

        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetAppleM4A
            )
        else {
            throw TranscriptionFailure.engine("this video's audio could not be read")
        }
        session.timeRange = CMTimeRange(start: .zero, duration: maximumDuration)

        // A stale file at the destination makes the export fail rather than overwrite.
        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            // A half-written container opens and produces nonsense, which is worse than nothing.
            try? FileManager.default.removeItem(at: destination)
            throw TranscriptionFailure.engine("this video's audio could not be read")
        }
        return .extracted(destination)
    }
}
