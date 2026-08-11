import Foundation
import UniformTypeIdentifiers

/// One share, staged by the extension and waiting for the app to file it.
///
/// **The extension stages; the app drains.** This record is the entire contract between the two,
/// and it exists because a share extension is the wrong process to finish the job in — see
/// `ShareViewController` for the three reasons and `docs/decisions.md` for the decision. Nothing
/// here reaches the network; the app turns it into an `Entry` and its `Media` rows through the
/// same pipeline the composer uses.
///
/// **Every id is client-generated**, matching the offline-creation rule the rest of the app
/// follows: the entry has an identity before the server has heard of it, so a share made on a
/// train is a real entry the moment the extension exits rather than a hopeful one.
nonisolated struct PendingShare: Codable, Equatable, Sendable, Identifiable {

    /// Bumped when a field's meaning changes. A record written by a newer extension than the app
    /// beside it — which is exactly what an in-progress upgrade looks like — is left alone rather
    /// than coerced into a shape it was never written in. Leaving it is safe: the two ship
    /// together, so the app that can read it is the next launch away.
    static let currentVersion = 1

    let version: Int

    /// The eventual `entry_id`. **This is what makes the drain idempotent** — draining twice
    /// finds the entry already in SwiftData and does nothing the second time.
    let id: UUID

    /// When the share happened, which becomes the entry's `created_at`.
    ///
    /// **Never conflated with `occurredAt`.** That distinction is a standing project rule and it
    /// is at its sharpest here: sharing a 2019 photo tonight is a row created tonight about a day
    /// in 2019, and an archive that files it under tonight is wrong in a way nobody notices until
    /// it is too late to fix.
    let createdAt: Date

    /// **When it happened.** Derived from the media's own capture metadata wherever there is
    /// any — see `resolveOccurredAt`. The timeline sorts by this.
    let occurredAt: Date

    /// Which of the two `occurredAt` actually is. Recorded rather than inferred, so the app and
    /// the extension's own UI can both say plainly whether a date was read off the photo or
    /// defaulted, instead of the parent having to guess from whether it looks plausible.
    let occurredAtSource: DateSource

    /// Optional, and optional means optional: a photo alone is a complete entry. Nil rather than
    /// empty when nothing was typed, matching how the composer stores an empty body.
    let note: String?

    let media: [Item]

    init(
        version: Int = PendingShare.currentVersion,
        id: UUID = UUID(),
        createdAt: Date,
        occurredAt: Date,
        occurredAtSource: DateSource,
        note: String?,
        media: [Item]
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.occurredAt = occurredAt
        self.occurredAtSource = occurredAtSource
        self.note = note
        self.media = media
    }

    /// One staged file.
    ///
    /// Deliberately thin. It carries where the bytes are and what the archive needs to know about
    /// when they were made — and **not** a content type, because the file here is still whatever
    /// Photos handed over. The archive's format is decided by the conversion the app runs on the
    /// way in (`ImagePipeline` for photos, `VideoPipeline` for video), and a content type written
    /// down before that conversion would be a claim about the source masquerading as a claim
    /// about the archive.
    nonisolated struct Item: Codable, Equatable, Sendable, Identifiable {
        /// The eventual `media_id`, so the staged filename is already right and nothing is
        /// renamed later. Same reasoning as `MediaDraft.id`.
        let id: UUID
        /// Relative to the inbox's media directory. **A filename, never an absolute URL** — a URL
        /// captured inside a container is not stable across launches, and one captured inside the
        /// extension's own sandbox is invalid the moment the extension dies.
        let filename: String
        let kind: ShareMediaKind
        let byteCount: Int
        /// EXIF `DateTimeOriginal` for a photo, the asset's creation date for a video, nil where
        /// the file carried neither.
        let capturedAt: Date?

        init(id: UUID, filename: String, kind: ShareMediaKind, byteCount: Int, capturedAt: Date?) {
            self.id = id
            self.filename = filename
            self.kind = kind
            self.byteCount = byteCount
            self.capturedAt = capturedAt
        }
    }

    /// Where `occurredAt` came from.
    nonisolated enum DateSource: String, Codable, Sendable {
        /// Read off the file — EXIF for a photo, the asset's creation date for a video.
        case captureMetadata
        /// Nothing on the file said when it was taken, so the moment of sharing stood in.
        case shareTime
    }
}

// MARK: - Resolving the date

nonisolated extension PendingShare {

    /// What `occurred_at` should be for a set of shared files.
    ///
    /// **A photo shared from Photos is usually not from today**, and this is the whole reason the
    /// share sheet needs its own thinking about dates. Defaulting to now would file a 2023 photo
    /// under this week, and the mistake is invisible: the entry looks completely normal, on the
    /// wrong day, permanently.
    ///
    /// The **earliest** capture date among them, not the latest and not now — the same rule
    /// `MediaDraftBuilder.suggestedOccurredAt` has always applied to the composer's picked photos,
    /// which now calls this so there is one rule rather than two that agree today. Picking three
    /// photos from an afternoon files the entry on that afternoon, and one of them having no date
    /// does not drag the entry forward to today.
    ///
    /// `now` only when *nothing* carried a date, because a guess in a permanent archive is worse
    /// than an honest default — and the default is recorded as one, so it can be said out loud.
    static func resolveOccurredAt(
        captures: [Date?],
        now: Date = Date()
    ) -> (date: Date, source: DateSource) {
        guard let earliest = captures.compactMap({ $0 }).min() else {
            return (now, .shareTime)
        }
        return (earliest, .captureMetadata)
    }
}

// MARK: - What may be shared

/// The two things this extension accepts.
///
/// Images and videos, and nothing else. A URL, a text selection, a PDF or an arbitrary file each
/// need a composer path that does not exist and a staging shape nothing downstream can read, so
/// each would be scope rather than a free extra.
///
/// **This is the second of two gates and the belt to the plist's braces.** The real one is
/// `NSExtensionActivationRule` in `RascalShare-Info.plist`, which is what stops the extension
/// being offered for a web page in the first place; this one runs over whatever an item provider
/// actually turns out to be carrying, which is not always what the activation rule implied.
nonisolated enum ShareMediaKind: String, Codable, Sendable, CaseIterable {
    case photo
    case video

    /// The kind this type should be staged as, or nil to refuse it.
    ///
    /// Conformance rather than equality, because Photos hands over concrete types — `public.jpeg`,
    /// `public.heic`, `com.apple.quicktime-movie` — and enumerating them is a list that goes stale
    /// the first time Apple adds a format.
    ///
    /// Movie is tested before image deliberately. Nothing conforms to both today; the ordering is
    /// there so that if something ever does, it is staged as the larger, more fragile thing rather
    /// than being handed to an image decoder.
    static func resolve(_ type: UTType) -> ShareMediaKind? {
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .photo }
        return nil
    }

    /// The `Media.kind` this becomes, which the server reads to decide single-PUT versus
    /// multipart and to derive `entry_type`. Same strings the composer sends.
    var mediaKind: String { rawValue }
}
