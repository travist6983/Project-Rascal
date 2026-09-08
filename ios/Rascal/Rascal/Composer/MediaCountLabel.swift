import Foundation

/// The heading above whatever is attached to an entry, counting what is actually there.
///
/// **It read "1 photo" over a voice note until phase 148.** The composer has accepted voice notes
/// and video for as long as it has accepted photographs; the label was written when photographs
/// were the only thing it could hold, and nothing moved it afterwards. A heading that misnames
/// what sits under it is a small lie on the one screen whose whole promise is that what you save
/// is what you get back — and the true sentence costs nothing.
///
/// Numerals rather than words, because the label this replaces already used them and
/// `SectionLabel` sets the result at label size, where the difference is width rather than tone.
enum MediaCountLabel {

    /// What a kind is called when it is counted. **Order is the order the capture choices are
    /// offered in** — photos, then video, then voice — so a mixed row reads in the order the
    /// parent met the buttons.
    private enum Kind: CaseIterable {
        case photo, video, voice, other

        init(rawValue: String) {
            switch rawValue {
            case "photo": self = .photo
            case "video": self = .video
            case "audio": self = .voice
            default: self = .other
            }
        }

        /// **`other` exists so an unrecognised kind cannot silently become a photograph.** The
        /// server constrains `media.kind` to three values and every draft this app builds carries
        /// one of them, so this bucket should stay empty — but a fourth kind arriving from a
        /// future server must degrade to a vague heading rather than a wrong one.
        func phrase(_ count: Int) -> String {
            switch self {
            case .photo: count == 1 ? "1 photo" : "\(count) photos"
            case .video: count == 1 ? "1 video" : "\(count) videos"
            case .voice: count == 1 ? "1 voice note" : "\(count) voice notes"
            case .other: count == 1 ? "1 attachment" : "\(count) attachments"
            }
        }
    }

    /// The heading for a set of media kinds, as `media.kind` spells them: `photo`, `video`,
    /// `audio`.
    ///
    /// Empty in never produces a heading — both call sites render the row only when something is
    /// attached — but it answers "Attached" rather than an empty label, because an empty
    /// `SectionLabel` would collapse the stack spacing above the tiles rather than disappear.
    static func label(kinds: [String]) -> String {
        let counts = kinds.reduce(into: [Kind: Int]()) { tally, raw in
            tally[Kind(rawValue: raw), default: 0] += 1
        }
        let parts = Kind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return kind.phrase(count)
        }

        switch parts.count {
        case 0: return "Attached"
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return "\(parts.dropLast().joined(separator: ", ")) and \(parts[parts.count - 1])"
        }
    }
}
