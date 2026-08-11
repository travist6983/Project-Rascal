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

    /// The body line a card actually sets, and where it came from.
    ///
    /// A voice entry often has no note of its own — the parent recorded the child and wrote
    /// nothing. The transcript's opening line is then the only words the card can show, and it
    /// is set italic because they are somebody else's, not the parent's summary of them.
    struct BodyLine: Equatable, Sendable {
        let text: String
        let isQuote: Bool
    }

    let id: UUID
    let occurredAt: Date
    let title: String?
    /// Two lines' worth, three for a written entry. Nil for a sealed letter, which is the point
    /// of sealing it.
    let preview: String?
    /// The prompt this entry answered, quoted at the top of the card.
    ///
    /// **The card is built around this** — v3 leads with the question rather than the artifact.
    /// Nil for a freeform entry, and the zone drops out rather than reserving space: a parent
    /// who wrote something unprompted did not answer anything, and an empty quote rule above
    /// their words would be furniture.
    let prompt: String?
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
    /// The line of transcript that answers "why is this row on my screen".
    ///
    /// Set only under search, and only when the words that matched are in the *transcript* rather
    /// than in something the card would have shown anyway. A search result whose title contains
    /// the query needs no explanation; one that matched a sentence buried in four minutes of a
    /// four-year-old talking needs exactly this.
    var searchMatch: String?

    /// The mosaic has four shapes — one, two, three, and a 2×2 — so four is the most tiles a
    /// card ever draws. Past that the count is **overlaid on the fourth tile** rather than
    /// taking a tile of its own, which is what keeps a nine-photo card the same height as a
    /// four-photo one.
    static let maxTiles = 4

    var hasMedia: Bool { !thumbnails.isEmpty || overflow > 0 }

    /// Did-it entries carry the sage tint; everything else sits on surface.
    var isDidIt: Bool { type == .didIt }

    /// Why this row is here, else the parent's words, else the child's from the transcript.
    ///
    /// **The search match outranks the parent's own body**, and only under search. On the ordinary
    /// timeline a card shows what the parent wrote; in a list of results it has to show what
    /// matched, or a row whose only connection to the query is a sentence forty seconds into a
    /// recording looks like the search is broken.
    var bodyLine: BodyLine? {
        if let searchMatch { return BodyLine(text: searchMatch, isQuote: true) }
        if let preview { return BodyLine(text: preview, isQuote: false) }
        if let line = voice?.openingLine { return BodyLine(text: line, isQuote: true) }
        return nil
    }

    /// A written entry gets a third line, because the writing *is* the artifact — there is no
    /// photo above it competing for the card, and two lines truncate the one thing it holds.
    var bodyLineLimit: Int { type == .text ? 3 : 2 }

    /// The kind's tint, used for the quote rule and the leading chip. Colour carries meaning:
    /// terracotta is photo and video, periwinkle is voice and writing, sage is did-it.
    var tint: Tint {
        switch type {
        case .didIt: .sage
        case .audio, .text: .periwinkle
        default: .terracotta
        }
    }

    nonisolated enum Tint: Equatable, Sendable {
        case terracotta, periwinkle, sage
    }

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
    ///
    /// The quoted prompt comes from `entry.promptBody` and nowhere else. There used to be an
    /// `assignedPrompt` fallback the caller looked up from cached `Assignment` rows; see the note
    /// on `prompt` below for why it went.
    init(
        entry: Entry,
        media: [Media],
        searchQuery: String? = nil
    ) {
        let sealed = entry.unlockAtAge != nil
        let live = media.filter { $0.deletedAt == nil }
        // **Only photos and video go in the mosaic.** A voice note is media, but it is not a
        // picture — it has its own band on the card, and putting it in the grid gave a voice
        // entry a 242pt periwinkle rectangle above the player for the same recording.
        let pictures = live.filter { $0.mediaKind == .photo || $0.mediaKind == .video }
        // The server's count can exceed what is cached here: a photo still uploading from
        // another phone is real, it just has no bytes this device can draw. Claiming fewer
        // pictures than the archive holds would be the wrong way to be wrong.
        //
        // `serverMediaCount` counts every kind, so the locally-known non-pictures come back off
        // it. Where the server holds an audio row this phone has not cached, that leaves the
        // count one high — and erring towards "there is more here" beats erring towards a
        // picture the archive has and the card denies.
        let localNonPictures = live.count - pictures.count
        let total = sealed ? 0 : max(entry.serverMediaCount - localNonPictures, pictures.count)
        // Up to four tiles, and any remainder is a number printed on the fourth rather than a
        // fifth tile. A card holding nine photos is the same height as one holding four.
        let shown = sealed ? [] : Array(pictures.prefix(Self.maxTiles))

        let audio = live.first { $0.mediaKind == .audio }

        self.init(
            id: entry.id,
            occurredAt: entry.occurredAt,
            title: entry.title,
            // A sealed letter shows its title and nothing else. Rendering the first two lines
            // of something sealed until eighteen would make the seal decorative.
            preview: sealed ? nil : Self.preview(
                of: entry.body,
                lines: entry.type == .text ? 3 : 2
            ),
            // **`prompt_body` is on the list row now, so there is nothing to fall back to.**
            //
            // It used to be filled only by `GET /entries/{id}`, which left it nil on every
            // timeline row — so the card looked the completed assignment up in the local cache
            // to find the same sentence. `EntryOut` carries `prompt_body` today (verified in
            // phase 19: eleven of eleven assignment-backed rows returned it non-null), and the
            // fallback resolved nothing anyway, because `Assignment` rows are written only by
            // `SyncEngine` from a `/sync` response and sync pull ships behind `syncPullEnabled`,
            // which is off.
            //
            // A freshly composed entry is still correct offline and immediately, because
            // `ComposerView` writes the prompt onto the row at composition time — that write is
            // not this fallback and did not go with it.
            prompt: entry.promptBody,
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
            isAwaitingSync: entry.sync != .synced && entry.deletedAt == nil,
            // A sealed letter explains nothing about why it matched. The seal is the whole point,
            // and a search that quoted the inside of one would make it decorative.
            searchMatch: sealed ? nil : searchQuery.flatMap { query in
                Self.matchingLine(query: query, in: live.compactMap(\.transcript))
            }
        )
    }

    /// The sentence in a transcript that a query landed on.
    ///
    /// **Client-side, and deliberately less clever than the server.** Postgres stems, so a search
    /// for "running" finds "ran" — this cannot, and when it cannot the card simply shows nothing
    /// extra rather than guessing. A missing explanation is a smaller wrong than a wrong one.
    ///
    /// It is also limited by what the cache holds: `GET /entries` inlines `MediaSummary`, which
    /// carries no transcript, so the words are only here when this phone wrote them or has opened
    /// the entry before. That covers the case this exists for — reading back what the phone
    /// transcribed last night — and degrades to silence for the rest.
    static func matchingLine(query: String, in transcripts: [String]) -> String? {
        let terms = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return nil }

        for transcript in transcripts {
            for sentence in Self.sentences(of: transcript) {
                let folded = sentence.folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: nil
                )
                if terms.contains(where: { folded.contains($0) }) { return sentence }
            }
        }
        return nil
    }

    /// Cut a transcript into readable pieces.
    ///
    /// The transcriber writes one whitespace-normalised blob with no line breaks, so "the matching
    /// line" has to be recovered from punctuation. Sentences that survive are trimmed and
    /// non-empty; a transcript with no terminators at all comes back as itself, which is right —
    /// a child talking for ten seconds without pausing is one line.
    private static func sentences(of transcript: String) -> [String] {
        transcript
            .split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
