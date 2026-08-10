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
///
/// **The badge names what is inside when the cover cannot.** A gradient card is the common case
/// for a long time yet — `thumb_key` is null until thumbnails leave P0 — and without a word for
/// what it holds, a wash with two lines of text reads as a picture that failed to load. It is
/// therefore shown whenever there is no cover, and on a cover only for video, where the still
/// frame does not say the thing moves.
struct ThrowbackCard: View {
    let title: String
    let subtitle: String
    let cover: EntryCardModel.Thumbnail?
    /// What the section leads with — "Voice", "Written", "Letter". Nil where the cover says it.
    var badge: String?
    /// The kind's colour. Periwinkle is voice and writing, terracotta is everything else.
    var badgeTint: Color = .terracotta
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
                if let badge { badgeLabel(badge) }
            }
            .frame(width: 232, height: 148)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    // A tinted card gets a tinted hairline — `border` is tuned for cream and
                    // reads as dirt on the wash, the same reason `sealedBorder` exists.
                    .strokeBorder(hasCover ? Color.ink.opacity(0.08) : Color.sealedBorder,
                                  lineWidth: Layout.borderWidth)
            )
            .shadow(color: .ink.opacity(Layout.Shadow.opacity), radius: Layout.Shadow.blur / 2, y: Layout.Shadow.y)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .task(id: cover?.id) { await load() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// The picture, or the wash. Both are decoration behind the words — the caption carries
    /// everything this card says, so neither is an accessibility element of its own.
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
    ///
    /// Three stops rather than two: the ink holds to nearly a fifth of its weight through the
    /// lower half and is gone by 72% of the height, so the eyebrow stays legible over a bright
    /// frame without the whole picture going grey.
    @ViewBuilder
    private var scrim: some View {
        if hasCover {
            LinearGradient(
                stops: [
                    .init(color: .ink.opacity(0), location: 0.28),
                    .init(color: .ink.opacity(0.18), location: 0.54),
                    .init(color: .ink.opacity(0.62), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .accessibilityHidden(true)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .typeRole(.cardTitle)
                .foregroundStyle(hasCover ? Color.canvas : Color.ink)
            Text(subtitle)
                .typeRole(.metadata)
                .foregroundStyle(hasCover ? Color.canvas.opacity(0.86) : Color.inkMuted)
                // Two lines, so a memory whose only words are its own sentence is not cut to
                // half of one. Past that the card would grow and the rail would go ragged.
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .typeRole(.label)
            .foregroundStyle(badgeTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hasCover ? Color.canvas.opacity(0.92) : Color.surface, in: Capsule())
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The badge is read as part of the sentence rather than as a separate stop — it names the
    /// kind, which is exactly what someone would say aloud before the line itself.
    private var accessibilityLabel: String {
        [badge, title, subtitle].compactMap { $0 }.joined(separator: ". ")
    }

    private func load() async {
        #if canImport(UIKit)
        guard let cover else { return }
        image = await thumbnails?.image(for: cover.id, kind: cover.kind)
        #endif
    }
}
