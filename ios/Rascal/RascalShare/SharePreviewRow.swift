import SwiftUI

/// What is about to be filed, in the app's inset-frame treatment.
///
/// Deliberately the same shape and the same tokens as `MediaPreviewRow` in the composer —
/// 84pt tiles, `mediaInsetRadius`, a hairline border, a `+N` tile past four — rather than a
/// second look for the same job. Photos sit inset with padding rather than bleeding to the edge;
/// full-bleed photo cards are on the design system's rejected list.
///
/// **No remove control.** The composer has one because a composer is a place you build something
/// up in over minutes. A share sheet is a twelve-second screen acting on a selection the parent
/// just made in Photos, and the way to change that selection is to change it in Photos.
struct SharePreviewRow: View {
    let loaded: [ShareItemLoader.Loaded]

    /// Past this, the rest collapse into a `+N` tile. Four fits a phone width at this size
    /// without the tiles becoming too small to recognise a face in — the composer's number, for
    /// the composer's reason.
    private let visibleLimit = 4

    private var visible: [ShareItemLoader.Loaded] { Array(loaded.prefix(visibleLimit)) }
    private var overflow: Int { max(0, loaded.count - visibleLimit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(ShareCopy.heading(
                photos: loaded.count { $0.item.kind == .photo },
                videos: loaded.count { $0.item.kind == .video }
            ))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, one in
                        tile(one, position: index + 1)
                    }
                    if overflow > 0 { overflowTile }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    private func tile(_ one: ShareItemLoader.Loaded, position: Int) -> some View {
        Group {
            if let preview = one.preview, let image = UIImage(data: preview) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // Video, and a photo whose thumbnail could not be made. Terracotta, because
                // colour carries meaning and terracotta is photo and video — a grey box would
                // read as a picture that failed to load. The same answer `MediaPreviewRow` gives
                // a voice note, in that media's own colour.
                glyphTile(one)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
        .accessibilityElement()
        .accessibilityLabel(ShareCopy.mediaLabel(
            kind: one.item.kind,
            position: position,
            of: loaded.count,
            durationSeconds: one.durationSeconds
        ))
    }

    private func glyphTile(_ one: ShareItemLoader.Loaded) -> some View {
        ZStack {
            Color.terracottaSoft
            VStack(spacing: 4) {
                Image(systemName: one.item.kind == .video ? "video" : "photo")
                    .font(.system(size: 20, weight: .regular))
                if let seconds = one.durationSeconds {
                    Text(DurationText.clock(seconds))
                        .typeRole(.metadata)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Color.terracotta)
        }
    }

    private var overflowTile: some View {
        Text("+\(overflow)")
            .typeRole(.cardTitle)
            .foregroundStyle(Color.inkMuted)
            .frame(width: 84, height: 84)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            .accessibilityLabel("\(overflow) more, also being saved")
    }
}
