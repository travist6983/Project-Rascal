import SwiftUI

/// Periwinkle bars at a fixed 3pt pitch, filling whatever width they are given.
///
/// The bar count is read from the available width rather than fixed, so the block fills its row
/// on every device and at every Dynamic Type setting instead of leaving a gutter before the
/// duration. Heights come from a cheap deterministic function of the index — the same shape
/// every time a card scrolls back into view, because a waveform that reshuffles on scroll reads
/// as a loading state.
///
/// **These are not the recording's real levels.** No decoded audio is involved and none should
/// be: drawing a true waveform means fetching and decoding the file for every audio entry on a
/// screen that may hold fifty. What this says is "there is a voice note here, this long", which
/// is what the row is for.
struct StaticWaveform: View {
    /// 0...1 while something is playing. **Nil on a card**, where there is no playback to
    /// report and a part-filled waveform would claim the parent had listened to some of it.
    var progress: Double?
    var maxBarHeight: CGFloat = 23

    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let pitch = barWidth + gap
            let count = max(1, Int(((geometry.size.width + gap) / pitch).rounded(.down)))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(Color.periwinkle.opacity(opacity(at: index, of: count)))
                        .frame(width: barWidth, height: height(at: index))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: maxBarHeight)
        .accessibilityHidden(true)
    }

    /// `6 + (i * 29) % 18`, normalised. A stride of 29 against a span of 18 walks the whole
    /// range without settling into a visible repeat at any count the row actually uses.
    private func height(at index: Int) -> CGFloat {
        let steps = CGFloat(6 + (index * 29) % 18)
        return maxBarHeight * (steps / 23)
    }

    /// Played bars at full strength, the rest faint — so on the detail screen the waveform *is*
    /// the progress bar. With no progress to report every bar is drawn the same.
    private func opacity(at index: Int, of count: Int) -> Double {
        guard let progress else { return 0.45 }
        return Double(index) < Double(count) * progress ? 1 : 0.32
    }
}

/// The voice band on a timeline card: play affordance, waveform, duration.
///
/// It does not play anything. Tapping the card opens the entry, where `VoicePlayerView` is a
/// real player with a real audio session — a second playback surface in a scrolling list would
/// mean fifty `AVPlayer`s one flick apart, and a session left active behind a screen the parent
/// has already scrolled past.
struct EntryAudioRow: View {
    let durationSeconds: Int?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.periwinkle)
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.canvas)
            }
            .frame(width: 34, height: 34)

            StaticWaveform()

            if let durationSeconds {
                Text(DurationText.clock(durationSeconds))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.periwinkle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.periwinkleSoft, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}
