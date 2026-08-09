import Foundation

/// What a timeline row draws, flattened out of SwiftData before the view sees it.
///
/// Two reasons this is a value type rather than the `@Model` itself. It is `Equatable`, so
/// SwiftUI skips a card whose content has not changed — which is most of them, on most renders,
/// in a list of five hundred. And it can be built in a test with no store, so the rules below
/// are assertable: a text entry has no thumbnails, a did-it entry stays did-it, a sealed letter
/// shows nothing it is meant to be keeping.
nonisolated struct EntryCardModel: Identifiable, Equatable, Sendable {

    /// One picture's worth of tile. Kind decides the placeholder, and whether the thumbnail may
    /// be fetched at all — video is never pulled down for a poster frame.
    struct Thumbnail: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: PromptKind
        let durationSeconds: Int?
    }

    /// A voice entry's chip: how long it runs, and the first line of what was said.
    struct Voice: Equatable, Sendable {
        let durationSeconds: Int?
        let openingLine: String?
    }

    let id: UUID
    let occurredAt: Date
    let title: String?
    /// Two lines' worth. Nil for a sealed letter, which is the point of sealing it.
    let preview: String?
    let type: EntryType?
    let ageMonths: Int?
    let tags: [String]
    /// The tiles to draw, already capped. Empty for a text or did-it entry, and the card must
    /// lay out with no gap where they would have been.
    let thumbnails: [Thumbnail]
    /// How many more pictures exist than there are tiles. Drives the `+8` tile.
    let overflow: Int
    let voice: Voice?
    /// `unlock_at_age` is set — a letter, sealed until he is old enough.
    let isSealed: Bool
    let unlockAtAge: Int?
    /// Written here, not yet acknowledged by the server. Never rendered as an error or a loss.
    let isAwaitingSync: Bool

    /// At most four tiles fit across a card at 56pt with the gaps the layout uses. Past that,
    /// three and a count reads better than four and a count.
    static let maxTiles = 4

    var hasMedia: Bool { !thumbnails.isEmpty || overflow > 0 }

    /// Did-it entries carry the sage tint; everything else sits on surface.
    var isDidIt: Bool { type == .didIt }

    /// What the type chip says. "Written", not "Text" — a parent wrote it, they did not enter
    /// data.
    var typeLabel: String? {
        switch type {
        case .photo: "Photo"
        case .video: "Video"
        case .audio: "Voice"
        case .text: "Written"
        case .didIt: "Did it"
        case .unknown(let raw): raw.isEmpty ? nil : raw.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: nil
        }
    }
}

@MainActor
extension EntryCardModel {

    /// Build a row from a cached entry and the media rows that belong to it.
    ///
    /// `media` is expected to be that entry's live media, oldest first — the order they were
    /// attached, which is the order a multi-photo card should show them in.
    init(entry: Entry, media: [Media]) {
        let sealed = entry.unlockAtAge != nil
        let live = media.filter { $0.deletedAt == nil }
        // The server's count can exceed what is cached here: a photo still uploading from
        // another phone is real, it just has no bytes this device can draw. Claiming fewer
        // pictures than the archive holds would be the wrong way to be wrong.
        let total = sealed ? 0 : max(entry.serverMediaCount, live.count)

        let shown: [Media]
        if total <= Self.maxTiles {
            shown = sealed ? [] : live
        } else {
            shown = Array(live.prefix(Self.maxTiles - 1))
        }

        let audio = live.first { $0.mediaKind == .audio }

        self.init(
            id: entry.id,
            occurredAt: entry.occurredAt,
            title: entry.title,
            // A sealed letter shows its title and nothing else. Rendering the first two lines
            // of something sealed until eighteen would make the seal decorative.
            preview: sealed ? nil : Self.preview(of: entry.body),
            type: entry.type,
            ageMonths: entry.childAgeMonths,
            tags: sealed ? [] : entry.tagNames,
            thumbnails: shown.map {
                Thumbnail(id: $0.id, kind: $0.mediaKind, durationSeconds: $0.durationSeconds)
            },
            overflow: max(0, total - shown.count),
            voice: (sealed || audio == nil) ? nil : Voice(
                durationSeconds: audio?.durationSeconds,
                openingLine: Self.preview(of: audio?.transcript, lines: 1)
            ),
            isSealed: sealed,
            unlockAtAge: entry.unlockAtAge,
            isAwaitingSync: entry.sync != .synced && entry.deletedAt == nil
        )
    }

    /// Collapse whitespace so a body that starts with three blank lines does not render as an
    /// empty preview above a card that looks broken.
    static func preview(of text: String?, lines: Int = 2) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.prefix(lines).joined(separator: " ")
    }
}
