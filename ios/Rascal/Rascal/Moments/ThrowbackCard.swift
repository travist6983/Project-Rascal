import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// A throwback: "1 year ago", over a photo behind a soft scrim.
///
/// **Where there is no photo, the gradient stands alone.** No grey box, no broken-image glyph, no
/// placeholder that reads as a fault — half the archive is written or did-it entries and a
/// throwback to one of those should look like an invitation, not like a picture that failed.
///
/// Which treatment a card gets is decided from whether the section *has* a picture, not from
/// whether the picture has arrived. Deciding on arrival would flip the text from ink to cream
/// mid-scroll, which looks like a rendering bug rather than a load.
struct ThrowbackCard: View {
    let title: String
    let subtitle: String
    let cover: EntryCardModel.Thumbnail?
    let action: () -> Void

    @Environment(\.thumbnails) private var thumbnails
    @State private var image: PlatformImage?

    private var hasCover: Bool { cover != nil }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                background
                scrim
                caption
            }
            .frame(width: 232, height: 148)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            .shadow(color: .ink.opacity(Layout.Shadow.opacity), radius: Layout.Shadow.blur / 2, y: Layout.Shadow.y)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .task(id: cover?.id) { await load() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var background: some View {
        if hasCover {
            // Terracotta at rest under the picture, so cream text is legible from the first
            // frame and does not change colour when the image lands.
            Color.terracottaDeep
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
            #endif
        } else {
            Gradients.wash
        }
    }

    /// Only over a photo. The wash is already low-contrast and a scrim on top of it would turn
    /// an emotional beat into mud.
    @ViewBuilder
    private var scrim: some View {
        if hasCover {
            LinearGradient(
                colors: [.ink.opacity(0.05), .ink.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .typeRole(.cardTitle)
                .foregroundStyle(hasCover ? Color.surface : Color.ink)
            Text(subtitle)
                .typeRole(.metadata)
                .foregroundStyle(hasCover ? Color.surface.opacity(0.85) : Color.inkMuted)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        #if canImport(UIKit)
        guard let cover else { return }
        image = await thumbnails?.image(for: cover.id, kind: cover.kind)
        #endif
    }
}
