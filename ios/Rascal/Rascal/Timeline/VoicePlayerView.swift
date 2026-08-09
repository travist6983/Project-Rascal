import AVFoundation
import SwiftUI

/// Playing back a voice entry, and reading what was said.
///
/// **Playback only.** Recording is a separate run on a separate branch — it touches the composer
/// and would collide — so nothing here captures anything. An audio entry that already exists is
/// still a first-class entry, and it was previously unplayable, which made the transcript the
/// only way to know what was in it.
///
/// The transcript is set as readable text rather than as a caption under a control: it is what
/// the archive is actually keeping. `PATCH /media/{id}/derived` persisted those words from the
/// phone, and the server never regenerates them.
struct VoicePlayerView: View {
    let mediaId: UUID
    let durationSeconds: Int?
    let transcript: String?
    let localFile: URL?
    let api: APIClient

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var elapsed: Double = 0
    @State private var total: Double = 0
    @State private var loading = false
    @State private var notice: String?
    @State private var observer: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            control
            if let transcript, !transcript.isEmpty {
                Text(transcript)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Text(notice)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .onDisappear { stop() }
    }

    // MARK: The control

    private var control: some View {
        HStack(spacing: 14) {
            Button { Task { await toggle() } } label: {
                Group {
                    if loading {
                        ProgressView().tint(.surface)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.surface)
                    }
                }
                .frame(width: 46, height: 46)
                // Periwinkle is voice. A terracotta play button here would be the brand colour
                // overriding the meaning, which is a defect rather than a style choice.
                .background(Color.periwinkle, in: Circle())
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 6) {
                progressBar
                Text(timeLabel)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(Color.periwinkleSoft, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.periwinkle.opacity(0.22))
                Capsule()
                    .fill(Color.periwinkle)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    /// Zero until playback starts, which is honest — a bar that animates before anything is
    /// loaded is a bar pretending to be measurement.
    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// The server's `duration_seconds` before playback, the player's own once it knows.
    private var duration: Double {
        total > 0 ? total : Double(durationSeconds ?? 0)
    }

    private var timeLabel: String {
        let left = Int(duration.rounded()) - Int(elapsed.rounded())
        guard duration > 0 else { return "Voice note" }
        return "\(DurationText.clock(Int(elapsed))) · \(DurationText.clock(max(0, left))) left"
    }

    // MARK: Playing

    private func toggle() async {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if player == nil {
            loading = true
            defer { loading = false }
            guard let url = await MediaAccess.playbackURL(mediaId: mediaId, localFile: localFile, api: api) else {
                notice = "Can't play this right now. It's safe in the archive."
                return
            }
            // **Set explicitly, because the recorder leaves `.playAndRecord` on the shared
            // session and a category outlives the screen that set it.** Without this, playing a
            // voice entry after recording one routes through the recording category and, worse,
            // activates a session nothing deactivates — so the user's music stays ducked long
            // after they have left the archive.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            let created = AVPlayer(url: url)
            observe(created)
            player = created
        }
        player?.play()
        isPlaying = true
    }

    /// Progress comes from the player rather than from a timer, so the bar measures playback
    /// instead of animating alongside it.
    ///
    /// **`[weak player]` is not tidiness.** A player retains its periodic observer block, so a
    /// block that captures the player strongly is a cycle Apple documents by name — the player,
    /// its item, and the decoded audio all outlive the screen. `stop()` breaks it on the way
    /// out, but a view torn down without `onDisappear` firing would leak an entire AVPlayer, and
    /// this one is opened from a screen a parent can swipe away mid-sentence.
    private func observe(_ player: AVPlayer) {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak player] time in
            // Read out here, where the block already runs on the main queue, so the hop below
            // carries two plain numbers and captures nothing that can be mutated underneath it.
            let duration = player?.currentItem?.duration.seconds
            Task { @MainActor in
                elapsed = time.seconds
                if let duration, duration.isFinite, duration > 0 { total = duration }
            }
        }
    }

    private func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        // Handed back, always. A session left active is silence in someone's car an hour later,
        // with nothing on screen to connect it to this app.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
