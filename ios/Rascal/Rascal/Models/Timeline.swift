import Foundation

/// The wire shapes the archive screens read: `GET /entries`, `GET /entries/{id}`, and
/// `GET /children/{id}/moments`.
///
/// Deliberately separate from the SwiftData models, for the same reason `TodayResponse` is: the
/// API shape and the local cache shape are different concerns and will drift, and collapsing
/// them means every server change becomes a migration.

// MARK: - Pieces of an entry

nonisolated struct TagResponse: Decodable, Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    /// `user` or `device_ai`. Carried because a tag the phone's transcriber wrote and a tag a
    /// parent typed are not the same claim, even though they render the same today.
    let source: String
}

/// `MediaSummary`, and `MediaDetail` too — detail is the summary plus a transcript and a
/// caption, so the extra fields are optional here rather than living in a second type.
nonisolated struct MediaSummaryResponse: Decodable, Identifiable, Sendable {
    let id: UUID
    /// `photo` · `video` · `audio`.
    let kind: String
    let s3Key: String
    /// **Null for every row today.** Thumbnail and poster-frame generation was cut from P0
    /// server-side, so the client derives its own from the original — see `ThumbnailStore`.
    let thumbKey: String?
    let durationSeconds: Int?
    let bytes: Int
    let uploadStatus: String
    let capturedAt: Date?

    // Detail only.
    let transcript: String?
    let caption: String?

    var mediaKind: PromptKind { PromptKind(rawValue: kind) }

    /// The server has the bytes. Anything else has nothing this phone can render.
    var isComplete: Bool { MediaUploadState(rawValue: uploadStatus) == .complete }
}

/// The prompt an entry answered. `GET /entries/{id}` only.
nonisolated struct PromptRefResponse: Decodable, Sendable {
    let id: UUID
    let kind: String
    let cadence: String
    let completionMode: String
    let body: String
    let theme: String

    var promptKind: PromptKind { PromptKind(rawValue: kind) }
}

// MARK: - Pages

nonisolated struct EntryPageResponse: Decodable, Sendable {
    let entries: [EntryResponse]
    /// Opaque, and it encodes `(occurred_at, id)` — keyset paging, never an offset, because
    /// backdating inserts rows into the middle of the order. Null on the last page.
    let nextCursor: String?
}

// MARK: - Moments

/// `GET /children/{id}/moments`. All four keys are always present: `groups` is filled on a hit,
/// `entries` on the warm redirect, and `fallback` says which happened.
nonisolated struct MomentsResponse: Decodable, Sendable {
    /// The date the server looked at, in the child's timezone. `YYYY-MM-DD`, never parsed into
    /// a `Date` here — it is a calendar day the server computed, not an instant.
    let date: String
    /// `"random"` when there was nothing on this day in prior years.
    let fallback: String?
    let groups: [MomentGroupResponse]
    let entries: [EntryResponse]

    var isFallback: Bool { fallback != nil }

    /// Everything to render, whichever branch the server took.
    var allEntries: [EntryResponse] {
        groups.flatMap(\.entries) + entries
    }
}

nonisolated struct MomentGroupResponse: Decodable, Sendable, Identifiable {
    let yearsAgo: Int
    let entries: [EntryResponse]

    var id: Int { yearsAgo }

    /// "1 year ago", "6 years ago". Nothing counts down and nothing is a milestone.
    var title: String {
        yearsAgo == 1 ? "1 year ago" : "\(yearsAgo) years ago"
    }
}

// MARK: - Filtering

/// The timeline's filter row. Maps to the `type` query parameter, and to `entry_type` on a
/// locally cached row so the same filter works with no connection.
///
/// **`sealed` is the exception and it is deliberate.** A sealed letter is `unlock_at_age` being
/// set, not an `entry_type`, so there is no `?type=` value that expresses it — see
/// `isClientSideOnly` for what the client does instead, and `docs/blocked.md` for the server
/// parameter that would make it unnecessary.
nonisolated enum TimelineFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case photo
    case video
    case audio
    case text
    case didIt
    case sealed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .photo: "Photos"
        case .video: "Video"
        case .audio: "Voice"
        case .text: "Written"
        case .didIt: "Did it"
        case .sealed: "Sealed"
        }
    }

    /// How the empty state names this kind: "No **voice notes** so far."
    ///
    /// Separate from `title`, because a chip label and a sentence are different jobs. Reusing
    /// the chip gave "No photos entries so far", which is the sort of thing that reads as
    /// carelessness in an app someone is trusting with their child's childhood.
    var emptyNoun: String {
        switch self {
        case .all: "entries"
        case .photo: "photos"
        case .video: "video"
        case .audio: "voice notes"
        case .text: "written entries"
        case .didIt: "did-it entries"
        case .sealed: "sealed letters"
        }
    }

    /// What goes on the wire as `?type=`.
    ///
    /// Nil for `all`, which sends no `type` at all — and nil for `sealed`, which the server has
    /// no parameter for. **The two nils do not mean the same thing**, which is what
    /// `isClientSideOnly` exists to say out loud.
    var serverType: String? {
        switch self {
        case .all, .sealed: nil
        case .photo: EntryType.photo.rawValue
        case .video: EntryType.video.rawValue
        case .audio: EntryType.audio.rawValue
        case .text: EntryType.text.rawValue
        case .didIt: EntryType.didIt.rawValue
        }
    }

    /// True when the server cannot express this filter, so the client asks for the whole
    /// archive and narrows it locally.
    ///
    /// The consequence is real and it is why `TimelineModel` has a loop: a page of fifty
    /// entries can contain no sealed letters at all, and a page that adds no visible row also
    /// adds nothing to trigger the next one. Paging has to keep going on its own until it finds
    /// something or runs out of archive.
    var isClientSideOnly: Bool { serverType == nil && self != .all }

    /// The same decision against a cached row, so an offline filter and an online one agree.
    ///
    /// A locally-created entry whose type the server has not derived yet has no `entry_type` at
    /// all. It matches `All` and nothing else: guessing a type on device would be the client
    /// deciding something the server owns, and it would be wrong exactly when media is still
    /// uploading — a photo entry that looks like a text one.
    ///
    /// `unlockAtAge` is what makes a letter sealed, and it is set by the parent at write time
    /// rather than derived — so unlike `entry_type` it is trustworthy on a row the server has
    /// never seen.
    func matches(entryType: String?, unlockAtAge: Int? = nil) -> Bool {
        if self == .sealed { return unlockAtAge != nil }
        guard let serverType else { return true }
        return entryType == serverType
    }
}
