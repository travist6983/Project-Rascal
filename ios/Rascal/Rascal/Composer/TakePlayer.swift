import AVFoundation
import SwiftUI

/// Hearing a take back before committing to it.
///
/// Deliberately separate from `VoicePlayerView`, which plays an entry that already exists in the
/// archive and fetches its bytes through a presigned URL. This one plays a file on disk that the
/// microphone finished writing seconds ago, and it has to scrub — the review step is where
/// someone decides whether a recording is worth keeping, and they cannot decide that without
/// being able to skip to the middle of it.
@MainActor
@Observable
final class TakePlayer {

    private(set) var isPlaying = false
    /// Seconds. Written from the player's own clock, so the scrubber measures playback rather
    /// than animating alongside it.
    private(set) var position: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Load and play, or pause if this file is already going.
    func toggle(url: URL, duration: TimeInterval) {
        if isPlaying {
            pause()
            return
        }
        if player == nil || player?.url != url {
            // `.playback` for the duration of listening: the recording category routes to the
            // earpiece on some devices, which makes a review sound broken when it is not.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        }
        guard let player else { return }
        // Starting from the end replays from the top rather than doing nothing.
        if position >= duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func seek(to seconds: TimeInterval) {
        position = max(0, seconds)
        player?.currentTime = position
    }

    /// Stop and hand the audio session back.
    ///
    /// **Always called when the review screen goes away.** A session left active keeps the
    /// user's music ducked, and the only symptom is silence in the car an hour later.
    func stop() {
        stopTicking()
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            let owner = self
            Task { @MainActor in owner?.tick() }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        position = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            stopTicking()
        }
    }
}

/// Play/pause and a draggable position, for the review step.
struct TakeScrubber: View {
    let player: TakePlayer
    let url: URL
    let duration: TimeInterval

    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.toggle(url: url, duration: duration)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.surface)
                    .frame(width: 44, height: 44)
                    // Periwinkle is voice, here as everywhere else.
                    .background(Color.periwinkle, in: Circle())
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 6) {
                Slider(
                    value: Binding(
                        get: { dragging ?? min(player.position, duration) },
                        set: { dragging = $0 }
                    ),
                    in: 0...max(duration, 0.1),
                    onEditingChanged: { editing in
                        // Seek on release rather than continuously: scrubbing an AAC file on
                        // every frame of a drag stutters, and the thumb is already showing where
                        // it will land.
                        if !editing, let target = dragging {
                            player.seek(to: target)
                            dragging = nil
                        }
                    }
                )
                .tint(.periwinkle)

                Text("\(DurationText.clock(Int(dragging ?? player.position))) · \(DurationText.clock(Int(duration.rounded())))")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(Color.periwinkleSoft, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
    }
}
