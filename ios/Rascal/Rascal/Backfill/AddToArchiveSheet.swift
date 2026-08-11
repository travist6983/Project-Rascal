import SwiftUI

/// What the **+** button asks for.
///
/// Deliberately a small enum rather than four closures: the sheet has to **dismiss before** any of
/// these can present, because presenting a sheet from a sheet that is on its way out drops the
/// second one. So the sheet records what was chosen, closes, and the root acts on it.
enum AddToArchiveChoice: Equatable {
    case compose(ComposerOpening)
    case backfill
}

/// The sheet behind **+**.
///
/// **This replaced a one-tap composer, and that was a deliberate reversal** — see
/// `docs/decisions.md`. The camera roll is a browse action, not a fifth way to capture something,
/// and it needed a home where it could say what is actually waiting without sitting inside the
/// form someone opened to write. The cost is a tap on the way to every entry, which is the part
/// worth watching.
///
/// The backfill row is **absent entirely** when there is nothing to offer. A row that says
/// "nothing to backfill" is noise, and this sheet is on the path to every entry the app records.
struct AddToArchiveSheet: View {
    let clusters: [BackfillCluster]
    let onChoose: (AddToArchiveChoice) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The newest unlogged month — the one a parent is likeliest to still remember.
    private var offered: BackfillCluster? { Self.offer(from: clusters) }

    /// What, if anything, this sheet offers.
    ///
    /// **Nil is the important answer.** The row is absent entirely rather than present and empty:
    /// this sheet sits on the path to every entry the app records, and a permanent row reading
    /// "nothing to backfill" would be a standing reminder of an absence. `clusters` is already
    /// filtered by the scan — months with entries, months under the minimum, and months set aside
    /// never reach here — so an empty list genuinely means there is nothing to offer.
    static func offer(from clusters: [BackfillCluster]) -> BackfillCluster? {
        clusters.first
    }

    var body: some View {
        // Scrollable and detent-flexible rather than a fixed height: at the largest Dynamic Type
        // sizes four labelled tiles plus a two-line offer are considerably taller than the sheet,
        // and a fixed detent clips the backfill row off the bottom — the one row this sheet was
        // reversed for.
        ScrollView {
            content
        }
        .background(Color.canvas)
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to the archive")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .padding(.bottom, 14)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                verb("Photo", symbol: "photo.on.rectangle", opening: .library)
                verb("Camera", symbol: "camera", opening: .camera)
                verb("Voice", symbol: "mic", opening: .recorder)
                verb("Write", symbol: "pencil", opening: .writing)
            }

            if let offered {
                Divider()
                    .overlay(Color.border)
                    .padding(.top, 18)
                backfillRow(offered)
            }
        }
        .padding(Layout.screenMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verb(_ label: String, symbol: String, opening: ComposerOpening) -> some View {
        Button {
            choose(.compose(opening))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.terracotta)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.terracottaSoft,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                Text(label)
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(TapScaleButtonStyle())
    }

    /// The offer.
    ///
    /// **Factual, and never a tally.** "62 photos from October 2025" is a count of what is in the
    /// camera roll; "you've missed six months" would be an accusation, and the app does not keep
    /// that score. Only the newest month is named here — the rest are one tap further in, where
    /// browsing is the point.
    private func backfillRow(_ cluster: BackfillCluster) -> some View {
        Button {
            choose(.backfill)
        } label: {
            // Top-aligned, not centred. At the largest Dynamic Type sizes the offer runs to four
            // lines and a centred icon floats out beside the middle of the sentence, reading as a
            // stray mark rather than as the row's own glyph.
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.terracotta)
                    .frame(width: 44, height: 44)
                    .background(
                        Color.terracottaSoft,
                        in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Browse your camera roll")
                        .typeRole(.cardTitle)
                        .foregroundStyle(Color.ink)
                    Text(Self.offerLine(cluster))
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkFaint)
            }
            .padding(.top, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Browse your camera roll. \(Self.offerLine(cluster))")
        .accessibilityAddTraits(.isButton)
    }

    /// "62 photos from October 2025, nothing logged."
    static func offerLine(_ cluster: BackfillCluster) -> String {
        let photos = cluster.assetCount == 1 ? "1 photo" : "\(cluster.assetCount) photos"
        return "\(photos) from \(cluster.month.label()), nothing logged."
    }

    private func choose(_ choice: AddToArchiveChoice) {
        dismiss()
        onChoose(choice)
    }
}
