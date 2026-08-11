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

    /// Decoded once, when the row appears, and never again.
    ///
    /// **Not `UIImage(data:)` inside `body`.** That is what the composer's `MediaDraft.image` does,
    /// and it is fine in the app — but `body` re-runs whenever SwiftUI decides it might need to,
    /// which here includes anything that invalidates the screen while a parent is typing a note.
    /// Four 400px thumbnails is a couple of megabytes of pixels per pass; in the app that is
    /// nothing, and in a process with a hard memory ceiling it is a cost nobody is measuring.
    ///
    /// The fix is not to reason about how often SwiftUI re-evaluates. It is to decode once.
    @State private var decoded: [UUID: Image] = [:]

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
        // Keyed on what is actually drawn: only the visible tiles are ever decoded, so a
        // twenty-photo share costs four thumbnails rather than twenty.
        .task(id: visible.map(\.id)) {
            var next: [UUID: Image] = [:]
            for one in visible {
                if let existing = decoded[one.id] {
                    next[one.id] = existing
                } else if let data = one.preview, let image = UIImage(data: data) {
                    next[one.id] = Image(uiImage: image)
                }
            }
            decoded = next
        }
    }

    private func tile(_ one: ShareItemLoader.Loaded, position: Int) -> some View {
        Group {
            if let image = decoded[one.item.id] {
                image.resizable().scaledToFill()
            } else if one.item.kind == .photo, one.preview != nil {
                // Decoded on the next turn of the run loop. A flat surface rather than the glyph,
                // so a photo does not flash a video-shaped placeholder on its way in.
                Color.surface
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
