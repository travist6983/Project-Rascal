import AVFoundation
import Foundation
import Testing

@testable import Rascal

/// Pulling the audio out of a video so the existing transcriber can read it.
///
/// **Deliberately not a stub.** Every assertion here is about what a *file* turns out to be —
/// whether a real mp4 yields a real m4a, whether a silent one is recognised as silent — and a
/// fake would make all of them assert nothing. That is the same reasoning `writeRecording` states
/// for the audio fixtures, and it matters more here: the whole phase exists because
/// `AVAudioFile(forReading:)` cannot open an mp4, which is a fact about containers rather than
/// about our code.
@MainActor
@Suite("A video's audio track")
struct VideoAudioTrackTests {

    // MARK: Fixtures

    /// A real mp4, written by `AVAssetWriter`, with or without an audio track.
    ///
    /// Video is a single black frame — the point is the container and the track list, not the
    /// picture, and a one-frame asset keeps the suite fast.
    private func writeVideo(seconds: Double, withAudio: Bool, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 160,
                AVVideoHeightKey: 120,
            ]
        )
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil
        )
        writer.add(video)

        var audio: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioPipeline.settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        adaptor.append(pixelBuffer!, withPresentationTime: .zero)
        video.markAsFinished()

        if let audio {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let samples = buffer.floatChannelData![0]
            for frame in 0..<Int(frames) {
                samples[frame] = sinf(Float(frame) * 2 * .pi * 440 / 44_100) * 0.4
            }
            if let sample = buffer.toCMSampleBuffer() {
                audio.append(sample)
            }
            audio.markAsFinished()
        }

        await writer.finishWriting()
    }

    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
    }

    // MARK: What it produces

    @Test("a normal video needs no export, because AVAudioFile reads mp4 directly")
    func extractsSomethingAVAudioFileCanRead() async throws {
        let source = scratch("with-audio.mp4")
        let destination = scratch("track.m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try await writeVideo(seconds: 0.5, withAudio: true, to: source)

        // The premise of the whole phase, asserted rather than assumed: the transcriber's own
        // opener cannot read the mp4. If this ever starts passing, the extraction step is dead
        // weight and should go rather than sit there being harmless.
        // **The finding that rewrote this phase.** The story assumed `AVAudioFile` could not open
        // an mp4, so a video's audio had to be exported first. It can, and it reads the real
        // samples — so the export was machinery for a problem that does not exist.
        let direct = try AVAudioFile(forReading: source)
        #expect(direct.length > 0)
        #expect(direct.fileFormat.sampleRate == 44_100)

        // Which is why a normal-length video needs nothing done to it.
        let plan = try await VideoAudioTrack.plan(for: source, exportingTo: destination)
        #expect(plan == .readDirectly)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a video with no audio track is silent, not an error")
    func aSilentVideoIsNotAFailure() async throws {
        // Silent clips, screen recordings, a covered mic. A row that failed six times against a
        // video that never had sound would be spending its retry budget on physics.
        let source = scratch("no-audio.mp4")
        let destination = scratch("track.m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try await writeVideo(seconds: 0.5, withAudio: false, to: source)

        let plan = try await VideoAudioTrack.plan(for: source, exportingTo: destination)

        #expect(plan == .silent)
        // Nothing written means nothing for a caller to clean up.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a file that is not a video fails rather than producing an empty track")
    func garbageInIsAFailure() async throws {
        let source = scratch("not-a-video.mp4")
        let destination = scratch("track.m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("this is not an mp4".utf8).write(to: source)

        // It must not come back `.silent`: that would mark the row done and never retry, which
        // is the wrong answer for a file that might be a transient download problem.
        await #expect(throws: (any Error).self) {
            _ = try await VideoAudioTrack.plan(for: source, exportingTo: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: What the queue now picks up

    @Test("video is transcribable, and photos still are not")
    func eligibilityIncludesVideo() {
        // Phase 16's one-line change, pinned. A photo joining this set would put every picture in
        // the archive through an analyzer that has nothing to say about it.
        #expect(TranscriptionQueue.isTranscribable(media(kind: .video, complete: true)))
        #expect(TranscriptionQueue.isTranscribable(media(kind: .audio, complete: true)))
        #expect(!TranscriptionQueue.isTranscribable(media(kind: .photo, complete: true)))
    }

    @Test("an incomplete video is not picked up, for the reason audio never was")
    func incompleteIsStillExcluded() {
        // `PATCH /media/{id}/derived` resolves a row the server has to already know about, so
        // transcribing first spends the whole retry budget on 404s.
        #expect(!TranscriptionQueue.isTranscribable(media(kind: .video, complete: false)))
    }

    private func media(kind: PromptKind, complete: Bool) -> Media {
        let row = Media(
            entryId: UUID(),
            kind: kind.rawValue,
            contentType: kind == .video ? "video/mp4" : "audio/mp4",
            byteCount: 1024
        )
        row.uploadState =
            (complete ? MediaUploadState.complete : MediaUploadState.staged).rawValue
        return row
    }
}

extension AVAudioPCMBuffer {
    /// A `CMSampleBuffer` for `AVAssetWriterInput`, which does not take PCM buffers directly.
    fileprivate func toCMSampleBuffer() -> CMSampleBuffer? {
        let audioBufferList = mutableAudioBufferList
        var format: CMFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: self.format.streamDescription,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format
            ) == noErr, let format
        else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(self.format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        guard
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                sampleCount: CMItemCount(frameLength), sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sample
            ) == noErr, let sample
        else { return nil }

        guard
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: audioBufferList
            ) == noErr
        else { return nil }

        return sample
    }
}
