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
/// **`sealed` is not an `entry_type`, and it now has a parameter of its own.** A sealed letter is
/// `unlock_at_age` being set, so no `?type=` value expresses it — it goes on the wire as
/// `?sealed=true` instead. That parameter is what this filter used to lack, and lacking it is why
/// the client used to ask for the whole archive and narrow it locally across a paging budget.
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
    /// Nil for `all`, which sends no `type` at all — and nil for `sealed`, which is expressed by
    /// `serverSealed` instead. Both nils now mean the same thing here: no `type` parameter. They
    /// did not always, which is what the deleted `isClientSideOnly` existed to say out loud.
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

    /// What goes on the wire as `?sealed=`.
    ///
    /// **`true` or absent, never `false`.** The server takes `sealed=false` too — it returns
    /// only unsealed rows — but no chip in this row means "everything except letters", so
    /// sending it would narrow a list nobody asked to narrow. `All` sends nothing and gets both.
    ///
    /// This replaced `isClientSideOnly`. Every chip is now a server filter, so one request per
    /// page is always enough and `TimelineModel` no longer keeps a paging budget for the case
    /// where a page of fifty entries contained no visible row.
    var serverSealed: Bool? { self == .sealed ? true : nil }

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
