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
    /// Rendered under the control when set. Entry Detail passes nil and sets the transcript
    /// itself, further down the screen where v3 puts it — as readable body copy under a label,
    /// rather than as a caption bolted to a control.
    let transcript: String?
    let localFile: URL?
    let api: APIClient
    /// Entry Detail's voice canvas: the player *is* the screen, so it stacks vertically at
    /// canvas scale on the periwinkle ground rather than sitting in a block of its own.
    ///
    /// **A parameter rather than a second view.** The loading, the playback, the elapsed clock
    /// and the waveform are all the same work, and the only things that differ are the size and
    /// whether there is a block behind it — which is exactly the case where forking costs two of
    /// everything and buys nothing. Defaults to the card, so nothing that existed changes.
    var prominent: Bool = false

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

    /// The hero block at the top of a voice entry: play, waveform, elapsed and total.
    ///
    /// **The waveform is the progress bar.** Bars behind the playhead are drawn at full strength
    /// and the rest faint, so there is one object doing one job rather than a decorative
    /// waveform above a functional rule. That is also why the bars are not the recording's real
    /// levels — see `StaticWaveform`.
    @ViewBuilder
    private var control: some View {
        if prominent { prominentControl } else { cardControl }
    }

    /// The canvas treatment: play, waveform and clock stacked and centred, on the ground the
    /// screen already paints. No block, no hairline — there is nothing to separate it from.
    private var prominentControl: some View {
        VStack(spacing: 26) {
            Button { Task { await toggle() } } label: {
                Group {
                    if loading {
                        ProgressView().tint(.canvas)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Color.canvas)
                    }
                }
                .frame(width: 84, height: 84)
                .background(Color.periwinkle, in: Circle())
                .shadow(color: .periwinkle.opacity(0.32), radius: 14, y: 10)
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            StaticWaveform(progress: fraction, maxBarHeight: 96)
                .frame(height: 96)

            if duration > 0 {
                Text("\(DurationText.clock(Int(elapsed))) / \(DurationText.clock(Int(duration.rounded())))")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.periwinkle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(DurationText.spoken(Int(elapsed))) of \(DurationText.spoken(Int(duration.rounded())))"
                    )
            } else {
                // The server had no `duration_seconds` and playback has not started, so there is
                // no length to state. Saying 0:00 would be a measurement nobody took.
                Text("Voice note")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.periwinkle)
            }
        }
    }

    private var cardControl: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button { Task { await toggle() } } label: {
                    Group {
                        if loading {
                            ProgressView().tint(.canvas)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(Color.canvas)
                        }
                    }
                    .frame(width: 52, height: 52)
                    // Periwinkle is voice. A terracotta play button here would be the brand
                    // colour overriding the meaning, which is a defect rather than a style
                    // choice.
                    .background(Color.periwinkle, in: Circle())
                }
                .buttonStyle(TapScaleButtonStyle())
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                StaticWaveform(progress: fraction, maxBarHeight: 44)
            }

            times
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(Color.periwinkleSoft, in: RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.heroRadius, style: .continuous)
                .strokeBorder(Color.periwinkleBorder, lineWidth: Layout.borderWidth)
        )
    }

    /// Elapsed on the left, the whole length on the right — the two numbers a player is asked
    /// for. Monospaced so the left one does not jitter the layout as it counts.
    @ViewBuilder
    private var times: some View {
        if duration > 0 {
            HStack {
                Text(DurationText.clock(Int(elapsed)))
                Spacer(minLength: 0)
                Text(DurationText.clock(Int(duration.rounded())))
            }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(Color.periwinkle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(DurationText.spoken(Int(elapsed))) of \(DurationText.spoken(Int(duration.rounded())))")
        } else {
            // The server had no `duration_seconds` and playback has not started, so there is no
            // length to state. Saying 0:00 would be a measurement nobody took.
            Text("Voice note")
                .typeRole(.metadata)
                .foregroundStyle(Color.periwinkle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
