import AVFoundation
import SwiftUI

/// One video, playing on Entry Detail's canvas, with the scrubber that drives it in the sheet.
///
/// **The state is here rather than in either view, because two views share it.** The canvas draws
/// the frames and the sheet draws the position, and a scrubber that kept its own idea of elapsed
/// time would drift from the picture above it within a second. One object, two readers.
///
/// It plays *in place*. Tapping the canvas control does not present anything — the design puts
/// the scrubber in the sheet precisely so the picture is never covered by chrome, which only
/// works if the picture stays where it is. `MediaViewerScreen` remains the fullscreen path and is
/// still reached the same way it always was, by tapping the frame itself.
@MainActor
@Observable
final class VideoPlayback {
    private(set) var isPlaying = false
    private(set) var loading = false
    /// Seconds played. Written by the time observer, and by a drag while it is in progress.
    private(set) var elapsed: Double = 0
    /// The player's own once it knows, the server's `duration_seconds` before that.
    private(set) var duration: Double = 0
    /// Stated under the picture when the file cannot be reached. Never an alert.
    private(set) var notice: String?

    private var player: AVPlayer?
    private var observer: Any?
    /// True while a thumb is down. The time observer stops writing `elapsed` for the duration, so
    /// the knob does not fight the finger dragging it.
    private var scrubbing = false

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// The layer the canvas draws. Nil until the first play, which is what keeps a timeline of
    /// video entries from opening ten players.
    var currentPlayer: AVPlayer? { player }

    func prime(durationSeconds: Int?) {
        if duration == 0, let durationSeconds { duration = Double(durationSeconds) }
    }

    func toggle(mediaId: UUID, localFile: URL?, api: APIClient) async {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if player == nil {
            loading = true
            defer { loading = false }
            guard let url = await MediaAccess.playbackURL(
                mediaId: mediaId, localFile: localFile, api: api
            ) else {
                notice = "Can't play this right now. It's safe in the archive."
                return
            }
            // **Set explicitly, for the reason `VoicePlayerView` gives.** The recorder leaves
            // `.playAndRecord` on the shared session and a category outlives the screen that set
            // it, so a video played after recording a voice note would otherwise route through
            // the recording category and leave the user's music ducked.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let created = AVPlayer(url: url)
            observe(created)
            player = created
        }
        notice = nil
        // Starting again from the end replays rather than sitting on the last frame doing
        // nothing, which is what a play button that does not play looks like.
        if duration > 0, elapsed >= duration - 0.15 { await seek(toFraction: 0) }
        player?.play()
        isPlaying = true
    }

    /// Called continuously while the thumb moves: the picture follows the finger, because a
    /// scrubber that only commits on release gives no feedback about where you are going.
    func scrub(toFraction value: Double) {
        guard duration > 0 else { return }
        scrubbing = true
        elapsed = min(duration, max(0, value * duration))
    }

    func endScrub() async {
        await seek(toFraction: fraction)
        scrubbing = false
    }

    func seek(toFraction value: Double) async {
        guard duration > 0, let player else { return }
        let target = CMTime(seconds: min(duration, max(0, value * duration)), preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = target.seconds
    }

    /// Released when the screen goes. A player left running behind a dismissed screen keeps the
    /// audio session active and the sound playing over whatever the parent opened next.
    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        elapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observe(_ player: AVPlayer) {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let item = player.currentItem {
                    let known = item.duration.seconds
                    if known.isFinite, known > 0 { self.duration = known }
                }
                // A drag owns the position while it is happening.
                guard !self.scrubbing else { return }
                self.elapsed = time.seconds
                if self.duration > 0, time.seconds >= self.duration - 0.05 {
                    self.isPlaying = false
                }
            }
        }
    }
}

/// The frames, and nothing else.
///
/// `AVPlayerLayer` rather than AVKit's `VideoPlayer`, because that view brings Apple's transport
/// controls with it — a second scrubber, over the picture, which is the exact arrangement the
/// design moved into the sheet to avoid.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        // The picture fills the canvas, matching the poster it replaces. A letterboxed frame
        // inside a full-bleed canvas would put two different shapes on one screen.
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Elapsed, a draggable position, and the length — **in the sheet, never over the picture.**
///
/// The track is the cream `border`; only the played part and the knob are terracotta. That is the
/// design file's own arrangement and it is the readable one: a terracotta track would leave the
/// played and unplayed halves the same colour.
struct EntryScrubber: View {
    let elapsed: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var body: some View {
        HStack(spacing: 12) {
            time(elapsed)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.border).frame(height: 4)
                    Capsule().fill(Color.terracotta).frame(width: width * fraction, height: 4)
                    Circle()
                        .fill(Color.terracotta)
                        .frame(width: 14, height: 14)
                        .shadow(color: .ink.opacity(0.22), radius: 3, y: 2)
                        .offset(x: width * fraction - 7)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in onScrub(value.location.x / max(1, width)) }
                        .onEnded { _ in onCommit() }
                )
            }
            .frame(height: 14)
            time(duration)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(
            "\(DurationText.spoken(Int(elapsed))) of \(DurationText.spoken(Int(duration.rounded())))"
        )
        .accessibilityAdjustableAction { direction in
            // VoiceOver gets the scrubber too. A drag gesture is not an affordance to someone
            // who cannot see where the thumb is.
            let step = duration > 0 ? 5 / duration : 0
            switch direction {
            case .increment: onScrub(min(1, fraction + step))
            case .decrement: onScrub(max(0, fraction - step))
            default: return
            }
            onCommit()
        }
    }

    private func time(_ seconds: Double) -> some View {
        Text(DurationText.clock(Int(seconds.rounded())))
            .typeRole(.metadata)
            .fontWeight(.semibold)
            .foregroundStyle(Color.inkMuted)
            .monospacedDigit()
    }
}
