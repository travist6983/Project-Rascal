import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The `AudioRecorder` component from `docs/design-system.md`, built to that spec:
/// periwinkle waveform on canvas, a large terracotta record button centred, elapsed time
/// beneath, cancel and confirm circles flanking.
///
/// **Under the thumb in under fifteen seconds.** Tapping an audio mission lands here with the
/// record button already where a thumb rests — no setup screen, no format picker, no "choose
/// input". The only decision on the way in is whether to press it.
///
/// Periwinkle throughout, because colour carries meaning in this app and periwinkle is voice.
/// A terracotta waveform would be the brand colour overriding the meaning.
struct AudioRecorderSheet: View {
    /// Handed a finished take. The composer turns it into a draft.
    let onFinish: (AudioPipeline.Recording) -> Void
    let onCancel: () -> Void

    @State private var pipeline = AudioPipeline()
    @State private var player = TakePlayer()
    @State private var confirmingCancel = false
    @State private var confirmingRerecord = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestCancel() }
                        .foregroundStyle(Color.inkMuted)
                }
            }
        }
        .task {
            pipeline.observeInterruptions()
            // Asked on arrival rather than on the first tap, so the system sheet is out of the
            // way before someone is holding a moment they want to catch.
            await pipeline.requestPermission()
        }
        .onDisappear {
            pipeline.stopObservingInterruptions()
            player.stop()
            // Last line of defence. Every route out of here is meant to stop or cancel first,
            // but if this view is ever torn down with a recorder still running, the file has to
            // be closed rather than left as an unopenable container.
            pipeline.finalizeForBackground()
        }
        // Backgrounding finalises rather than abandons. The bytes captured so far become a
        // playable file on disk; nothing is discarded because a phone call arrived.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pipeline.finalizeForBackground() }
        }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $confirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                pipeline.cancel()
                onCancel()
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("What you've recorded so far will be deleted.")
        }
        .confirmationDialog(
            "Record it again?",
            isPresented: $confirmingRerecord,
            titleVisibility: .visible
        ) {
            Button("Record again", role: .destructive) {
                player.stop()
                pipeline.discardAndReset()
            }
            Button("Keep this one", role: .cancel) {}
        } message: {
            Text("This take will be replaced.")
        }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch pipeline.state {
        case .denied:
            deniedState
        case .finished(let recording):
            reviewState(recording)
        case .failed(let message):
            failedState(message)
        case .idle, .recording, .paused:
            captureState
        }
    }

    /// Idle, recording and paused share one layout so the record button never moves under the
    /// thumb between them.
    private var captureState: some View {
        VStack(spacing: 28) {
            WaveformView(levels: pipeline.levels, isLive: pipeline.isRecording)
                .frame(height: 96)
                .padding(.horizontal, Layout.screenMargin)

            VStack(spacing: 6) {
                Text(DurationText.clock(Int(pipeline.elapsed)))
                    .typeRole(.title)
                    .monospacedDigit()
                    .foregroundStyle(pipeline.isAtWarning ? Color.terracottaDeep : Color.ink)
                Text(caption)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
            }

            controls
        }
        .padding(.bottom, 12)
    }

    private var caption: String {
        switch pipeline.state {
        case .recording:
            pipeline.isAtWarning ? "Ten minutes is the most one recording holds." : "Recording"
        case .paused(let canResume):
            canResume ? "Paused. What you've recorded is safe." : "Stopped. What you've recorded is safe."
        default:
            "Up to ten minutes."
        }
    }

    /// Cancel (×) · record · confirm (✓), exactly as the spec lays them out.
    private var controls: some View {
        HStack(spacing: 34) {
            circleButton(
                symbol: "xmark",
                tint: .inkMuted,
                label: "Discard recording",
                enabled: pipeline.state != .idle
            ) { requestCancel() }

            recordButton

            circleButton(
                symbol: "checkmark",
                tint: .terracotta,
                label: "Finish recording",
                enabled: canFinish
            ) { Task { await pipeline.stop() } }
        }
    }

    private var canFinish: Bool {
        switch pipeline.state {
        case .recording: pipeline.elapsed > 0.4
        case .paused: true
        default: false
        }
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.terracotta)
                    .frame(width: 84, height: 84)
                    .shadow(color: .terracotta.opacity(0.28), radius: 10, x: 0, y: 5)
                // A filled circle becomes a rounded square while running: the same button, in a
                // state you can read at a glance without a second control appearing.
                RoundedRectangle(cornerRadius: pipeline.isRecording ? 7 : 26, style: .continuous)
                    .fill(Color.surface)
                    .frame(
                        width: pipeline.isRecording ? 30 : 52,
                        height: pipeline.isRecording ? 30 : 52
                    )
            }
            .animation(
                reduceMotion ? Motion.completionReduced : Motion.completion,
                value: pipeline.isRecording
            )
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel(pipeline.isRecording ? "Pause recording" : "Start recording")
    }

    private func circleButton(
        symbol: String,
        tint: Color,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(enabled ? tint : Color.inkMuted.opacity(0.4))
                .frame(width: 52, height: 52)
                .background(Color.surface, in: Circle())
                .overlay(Circle().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
        }
        .buttonStyle(TapScaleButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// Listen before committing. Re-recording destroys a take, so it asks once — a stray tap
    /// must not be able to delete the thing someone just captured.
    private func reviewState(_ recording: AudioPipeline.Recording) -> some View {
        VStack(spacing: 26) {
            WaveformView(levels: pipeline.levels, isLive: false)
                .frame(height: 96)
                .padding(.horizontal, Layout.screenMargin)

            VStack(spacing: 10) {
                Text(DurationText.clock(Int(recording.duration.rounded())))
                    .typeRole(.title)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                Text("Have a listen before you keep it.")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }

            TakeScrubber(player: player, url: recording.url, duration: recording.duration)
                .padding(.horizontal, Layout.screenMargin)

            HStack(spacing: 34) {
                circleButton(
                    symbol: "arrow.counterclockwise",
                    tint: .inkMuted,
                    label: "Record again",
                    enabled: true
                ) { confirmingRerecord = true }

                Button {
                    player.stop()
                    Haptics.completion()
                    onFinish(recording)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.surface)
                        .frame(width: 84, height: 84)
                        .background(Color.terracotta, in: Circle())
                        .shadow(color: .terracotta.opacity(0.28), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(TapScaleButtonStyle())
                .accessibilityLabel("Keep this recording")

                // Balances the row. Cancel is in the toolbar, where it is out of thumb reach of
                // the button that keeps the take.
                Color.clear.frame(width: 52, height: 52).accessibilityHidden(true)
            }
        }
        .padding(.bottom, 12)
    }

    /// Calm, and never a dead end. No red, no scolding — the mission stays completable another
    /// way, and this screen says how to change your mind.
    private var deniedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text("The microphone is switched off")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text("You can turn it on in Settings whenever you like. You can still answer this one by writing or with a photo.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            #if canImport(UIKit)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 30)
            #endif
            Button("Not now") { onCancel() }
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .padding(Layout.screenMargin * 1.6)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text("Recording stopped")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text(message)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await pipeline.start() } }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 30)
        }
        .padding(Layout.screenMargin * 1.6)
    }

    // MARK: Actions

    private func toggleRecording() async {
        switch pipeline.state {
        case .recording:
            pipeline.pause(canResume: true)
        case .paused:
            pipeline.resume()
        default:
            if await pipeline.start() { Haptics.completion() }
        }
    }

    /// Nothing has been captured yet, so there is nothing to confirm losing.
    private func requestCancel() {
        if pipeline.state == .idle {
            onCancel()
            return
        }
        confirmingCancel = true
    }
}

/// Periwinkle bars, newest on the right.
///
/// Driven by `AVAudioRecorder`'s own metering rather than an `AVAudioEngine` tap — see
/// `AudioPipeline.sample()`. A flat line while idle is honest: there is nothing to draw yet.
struct WaveformView: View {
    let levels: [Float]
    let isLive: Bool

    var body: some View {
        GeometryReader { geometry in
            let count = AudioPipeline.meterHistoryLength
            let spacing: CGFloat = 3
            let width = max(2, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(isLive ? Color.periwinkle : Color.periwinkle.opacity(0.45))
                        .frame(width: width, height: height(at: index, in: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    /// Right-aligned: the newest sample is the rightmost bar, so the waveform reads as moving
    /// forward rather than filling from the left.
    private func height(at index: Int, in available: CGFloat) -> CGFloat {
        let count = AudioPipeline.meterHistoryLength
        let offset = count - levels.count
        let minimum: CGFloat = 3
        guard index >= offset else { return minimum }
        let level = CGFloat(levels[index - offset])
        return max(minimum, level * available)
    }
}
