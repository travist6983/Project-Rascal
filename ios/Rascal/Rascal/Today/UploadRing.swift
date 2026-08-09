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

    private var lineWidth: CGFloat { max(2, diameter * 0.09) }

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
                Circle().fill(Color.terracotta)
                Checkmark()
                    .trim(from: 0, to: drawn)
                    .stroke(Color.surface, style: StrokeStyle(lineWidth: lineWidth * 1.1, lineCap: .round, lineJoin: .round))
                    .padding(diameter * 0.28)
            }
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: isComplete) { _, done in
            guard done else { drawn = 0; return }
            // Drawn, not faded in. Reduce Motion still gets the fill — removing the feedback
            // entirely is a different bug, since the parent still needs to know the tap landed.
            withAnimation(reduceMotion ? .easeOut(duration: 0.25) : Motion.completion) {
                drawn = 1
            }
        }
        .onAppear {
            // Already-done cards on a fresh render start complete rather than replaying.
            if isComplete { drawn = 1 }
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
                    Button("Upload it") { onRetry(media) }
                        .typeRole(.metadata)
                        .foregroundStyle(Color.terracotta)
                }
            }

            if failures.count > 1 {
                Button("Upload all \(failures.count)", action: onRetryAll)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.terracotta)
            }
        }
        .padding(.top, 2)
    }
}
