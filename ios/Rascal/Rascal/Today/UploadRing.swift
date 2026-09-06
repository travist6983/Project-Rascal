import SwiftUI

/// The completion check with an upload ring around it.
///
/// One control rather than two states swapped at the end: the ring fills as bytes land, and
/// when it closes it hands straight into the check drawing itself. Upload and completion read
/// as one gesture, which is what makes finishing feel like something rather than like a status
/// field changing value.
struct UploadRing: View {
    /// 0…1 across every file on the entry, weighted by bytes.
    var fraction: Double
    /// Files still to land. Counts down 3, 2, 1 on a multi-photo entry.
    var remaining: Int
    /// Everything has landed — draw the check.
    var isComplete: Bool

    var diameter: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    /// The disc arriving. Overshoots slightly and settles — the difference between a state
    /// change and something happening.
    @State private var fillScale: CGFloat = 0.7
    /// 0 → 1 once, driving a ring that expands outward and fades.
    @State private var halo: CGFloat = 0

    private var lineWidth: CGFloat { max(2, diameter * 0.09) }

    /// Three beats on one timeline rather than three animations fired at once: the disc lands,
    /// the check draws behind it, the halo carries the motion outward. Still no confetti, no
    /// particles, no sound, no streak — the warmth is in timing.
    private func play() {
        guard !reduceMotion else {
            // The check still fills. Removing the feedback entirely is a different bug, since
            // the parent still needs to know the tap landed.
            withAnimation(.easeOut(duration: 0.25)) { drawn = 1; fillScale = 1 }
            halo = 1
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { fillScale = 1 }
        withAnimation(Motion.completion.delay(0.06)) { drawn = 1 }
        withAnimation(.easeOut(duration: 0.55)) { halo = 1 }
        Haptics.completion()
    }

    var body: some View {
        ZStack {
            // The track. Always present, so the ring appearing does not itself animate.
            Circle()
                .strokeBorder(Color.terracotta.opacity(0.18), lineWidth: lineWidth)

            if !isComplete {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(Color.terracotta, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
                    .animation(.easeInOut(duration: 0.3), value: fraction)

                if remaining > 1 {
                    // The count only earns its place when there is more than one left; "1"
                    // beside a nearly-full ring is noise.
                    Text("\(remaining)")
                        .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.terracotta)
                        .transition(.opacity)
                }
            } else {
                // A halo that expands and fades once. Not decoration stuck on top — it is the
                // ring itself continuing outward after it closes, so the eye follows one
                // movement from "saving" through "saved" instead of seeing two states swap.
                Circle()
                    .stroke(Color.terracotta.opacity(halo > 0 ? 0.35 * (1 - halo) : 0), lineWidth: lineWidth)
                    .scaleEffect(1 + halo * 0.9)

                Circle()
                    .fill(Color.terracotta)
                    .scaleEffect(fillScale)

                Checkmark()
                    .trim(from: 0, to: drawn)
                    .stroke(Color.surface, style: StrokeStyle(lineWidth: lineWidth * 1.25, lineCap: .round, lineJoin: .round))
                    .padding(diameter * 0.28)
                    .scaleEffect(fillScale)
            }
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: isComplete) { _, done in
            guard done else { drawn = 0; fillScale = 0.7; halo = 0; return }
            play()
        }
        .onAppear {
            // Already-done cards on a fresh render start complete rather than replaying — the
            // animation is for the moment it happens, not for every scroll past it.
            if isComplete { drawn = 1; fillScale = 1; halo = 1 }
        }
        .accessibilityHidden(true)
    }
}

/// The checkmark path, so it can be trimmed and drawn rather than faded in.
private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
        return path
    }
}

/// Per-file upload state, listed rather than summarised.
///
/// "1 of 3 uploaded" tells a parent nothing they can act on. Two failures means two rows, each
/// with its own retry, so it is obvious *which* photos need attention.
struct FailedUploadList: View {
    let failures: [Media]
    let onRetry: (Media) -> Void
    let onRetryAll: () -> Void

    /// **Whether *Upload it* can do anything** (phase 147).
    ///
    /// A household that may not add media has a server that will answer `402
    /// subscription_required` to every one of these rows, and `resetForManualRetry()` puts a
    /// `failed` row straight back to `staged` — so the button would reset, re-request, be refused,
    /// and return the row to exactly where it started, for as long as somebody kept pressing it.
    /// `SyncUploadsModel.canRetry` states the rule this follows in its own words: *"Never show a
    /// control that cannot act."*
    ///
    /// **The rows stay and only the action goes.** *"This photo hasn't uploaded yet"* is true and is
    /// the sentence a parent needs; what is not offered is a button that lies. The way to change the
    /// answer is on the **+** sheet and on the board's own notice, both of which are standing in
    /// exactly this state.
    @Environment(\.mayAddMedia) private var mayAddMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(failures, id: \.id) { media in
                HStack(spacing: 8) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.inkMuted)
                    // Nothing is lost: the file is on the phone and the entry exists. The
                    // wording says what happened and what it means, and does not imply a loss.
                    Text("This photo hasn't uploaded yet")
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                    Spacer(minLength: 0)
                    if mayAddMedia {
                        Button("Upload it") { onRetry(media) }
                            .typeRole(.metadata)
                            .foregroundStyle(Color.terracotta)
                    }
                }
            }

            if mayAddMedia, failures.count > 1 {
                Button("Upload all \(failures.count)", action: onRetryAll)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.terracotta)
            }
        }
        .padding(.top, 2)
    }
}
