import Foundation
import SwiftData

/// A local entry, mirroring the `entries` table in `docs/data-model.md`.
///
/// SwiftData is a cache, not a second source of truth. The server owns the schedule, expiry,
/// what day it is, and `entry_type`; this model stores what the parent wrote and what the
/// server said about it.
@Model
final class Entry {
    /// Client-generated, before any network call. Offline creation has to sync cleanly, and a
    /// server-assigned id would mean the row has no identity until the request returns.
    @Attribute(.unique) var id: UUID

    var childId: UUID
    /// Set when this entry completes an assignment. Nil for a freeform entry.
    var assignmentId: UUID?

    /// **When it happened.** The timeline sorts by this. Backdating is a first-class flow, so
    /// this is routinely not "now".
    var occurredAt: Date
    /// **When the row was made.** Never assigned from `occurredAt`, and never displayed where
    /// the parent expects "when it happened".
    var createdAt: Date
    /// Server-maintained by a trigger; sync filters on it. Local edits set it optimistically
    /// and the server's value wins on the next fetch.
    var updatedAt: Date
    /// Soft delete. Deletions sync as rows with this set, never as absences.
    var deletedAt: Date?

    var title: String?
    var body: String?

    /// **Server-derived and read-only.** The server ignores any value sent and resolves it
    /// from content — media wins, else a `did_it` assignment stays `did_it`, else text. Never
    /// set locally, and never display a locally guessed value.
    private(set) var entryType: String?

    /// Server-computed from `occurred_at` minus birthdate. Displayed, never calculated here.
    private(set) var childAgeMonths: Int?

    var unlockAtAge: Int?

    /// Tag names as the server last reported them, lowercased, for the chips on a card.
    ///
    /// A denormalised copy rather than a `Tag` model: tags are read-only in this phase — there
    /// is no tag editor — and a second `@Model` plus a relationship would be a migration and a
    /// join to render six characters.
    ///
    /// **Optional deliberately**, per rule 6 of `ios/CLAUDE.md`. A non-optional collection with
    /// a declaration default ought to migrate, but the failure mode when a mandatory attribute
    /// cannot be inferred is the app refusing to launch on every device that had the previous
    /// build — and nothing in this suite or in CI would catch it. Optional is always
    /// inferrable, and nil is honest here: it means the server has not said.
    var storedTagNames: [String]?

    /// The prompt this entry answered, cached so Entry Detail renders the quoted block when
    /// the phone is offline. Nil for a freeform entry, which is first-class and shows no block.
    var promptBody: String?
    /// `question` · `photo` · `video` · `audio` · `activity` · `letter`, from the same prompt.
    var promptKind: String?

    /// The server's count of live media on this entry, which may exceed the rows cached here —
    /// media still uploading from another device has no bytes this phone can render. Drives the
    /// `+N` overflow tile so the card never claims fewer photos than the archive holds.
    var serverMediaCount: Int = 0

    /// `pending` · `synced` · `failed`. Stored as text for the same reason the server uses
    /// `text` + CHECK: a new state must not require a migration.
    var syncState: String

    /// Stable across retries so a replay is recognised as the same write rather than a second
    /// row. Generated once, at creation.
    var idempotencyKey: UUID

    /// True once the server has the row, so the sweep knows whether an outstanding change is
    /// a creation (`POST`) or an edit (`PATCH`). Without it an edit made while offline would
    /// be re-POSTed, and the idempotency key would return the *original* body — silently
    /// discarding the edit and reporting success.
    var existsOnServer: Bool = false

    /// Set when the parent deleted this entry and `DELETE /entries/{id}` has not landed yet.
    ///
    /// Deleting is local-first like every other write: the row is marked and gone from the
    /// timeline before the request goes out. Without this flag a delete made on a train would
    /// look done, and the entry would reappear on the next device that synced.
    var deletionPending: Bool = false

    init(
        id: UUID = UUID(),
        childId: UUID,
        assignmentId: UUID? = nil,
        occurredAt: Date,
        createdAt: Date = Date(),
        title: String? = nil,
        body: String? = nil,
        unlockAtAge: Int? = nil
    ) {
        self.id = id
        self.childId = childId
        self.assignmentId = assignmentId
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.title = title
        self.body = body
        self.unlockAtAge = unlockAtAge
        self.syncState = SyncState.pending.rawValue
        self.idempotencyKey = UUID()
    }

    var sync: SyncState {
        get { SyncState(rawValue: syncState) }
        set { syncState = newValue.rawValue }
    }

    /// The tags to render. Not persisted — `storedTagNames` is.
    var tagNames: [String] {
        get { storedTagNames ?? [] }
        set { storedTagNames = newValue }
    }

    var type: EntryType? {
        entryType.map(EntryType.init(rawValue:))
    }

    var isDeleted: Bool { deletedAt != nil }

    /// The one place server truth is written back onto a local row.
    func applyServerResponse(_ response: EntryResponse) {
        existsOnServer = true
        entryType = response.entryType
        childAgeMonths = response.childAgeMonths
        updatedAt = response.updatedAt
        // **A deletion only ever goes one way.** There is no undelete anywhere in this system,
        // so a response that still shows the row live is a response that predates the delete —
        // a page already in flight, or a list the server had not rewritten yet. Assigning
        // `response.deletedAt` straight across would let one of those bring a deleted entry
        // back onto the timeline, which is the single worst thing a reconcile can do.
        if let serverDeleted = response.deletedAt, deletedAt == nil {
            deletedAt = serverDeleted
        }
        tagNames = response.tags.map(\.name)
        serverMediaCount = response.mediaCount
        // **The seal is whatever the archive ended up holding.** The server applies a letter
        // prompt's `default_unlock_age` on create, so a row can come back sealed when this device
        // sent nothing — and if the corrective `PATCH` in `createEntry` could not land, the phone
        // showing "not sealed" over an archive that says "opens at 13" is a divergence nothing in
        // this app would ever reconcile, because editing a seal has no UI. Copying it means the
        // card tells the truth about the permanent record.
        unlockAtAge = response.unlockAtAge
        // Only `GET /entries/{id}` carries the prompt. A list response must not blank a value
        // the detail fetch already cached.
        if let prompt = response.prompt {
            promptBody = prompt.body
            promptKind = prompt.kind
        }
        sync = .synced
    }

    /// Everything the server owns, written onto a row the timeline is reconciling.
    ///
    /// Separate from `applyServerResponse` because that one is the acknowledgement of a write
    /// *this phone* just made — the local values are already the server's values. Here the row
    /// may have been edited on another device, so the server's title, body, and date win too.
    func applyServerTruth(_ response: EntryResponse) {
        occurredAt = response.occurredAt
        createdAt = response.createdAt
        title = response.title
        body = response.body
        unlockAtAge = response.unlockAtAge
        applyServerResponse(response)
    }
}

nonisolated enum SyncState: RawRepresentable, Equatable, Sendable {
    case pending, synced, failed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "synced": self = .synced
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .pending: "pending"
        case .synced: "synced"
        case .failed: "failed"
        case .unknown(let raw): raw
        }
    }
}

/// `photo` · `video` · `audio` · `text` · `did_it`. Server-derived.
nonisolated enum EntryType: RawRepresentable, Equatable, Sendable {
    case photo, video, audio, text, didIt
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "photo": self = .photo
        case "video": self = .video
        case "audio": self = .audio
        case "text": self = .text
        case "did_it": self = .didIt
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .text: "text"
        case .didIt: "did_it"
        case .unknown(let raw): raw
        }
    }
}

// MARK: - Wire models

/// `POST /v1/entries`. `entry_type` is deliberately absent — the server derives it and
/// ignores anything sent, so including it would be a lie the client tells itself.
nonisolated struct EntryCreateRequest: Encodable {
    let id: UUID
    let childId: UUID
    let assignmentId: UUID?
    let occurredAt: Date
    let title: String?
    let body: String?
    let unlockAtAge: Int?
    let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case id, childId, assignmentId, occurredAt, title, body, unlockAtAge, tags
    }

    /// Written by hand for one field. **`unlock_at_age` is always sent, including as an explicit
    /// null**, where the synthesized encoder would drop the key entirely.
    ///
    /// "Not sealed" is a decision the parent made on a letter prompt, and an absent key cannot
    /// express a decision — it reads as "no opinion". The server does not currently tell the two
    /// apart on create (see `ComposerView.unsealOnServerIfNeeded`, and `docs/blocked.md`), so
    /// today this is the client being right ahead of the contract rather than a behaviour change.
    /// The moment `create_entry` starts distinguishing them, this is already correct.
    ///
    /// Every other optional keeps `encodeIfPresent`: the server reads an absent `title` and an
    /// absent `assignment_id` as "not supplied", which is exactly what they mean.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(childId, forKey: .childId)
        try container.encodeIfPresent(assignmentId, forKey: .assignmentId)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encode(unlockAtAge, forKey: .unlockAtAge)
        try container.encode(tags, forKey: .tags)
    }
}

/// `EntryOut` from the contract, and `EntryDetail` too.
///
/// One type for both, mirroring the server, where `EntryDetail` is `EntryOut` plus transcripts
/// and the originating prompt. Two Swift types for one server model is two things to keep in
/// step, and the pair would drift the first time a field is added.
///
/// The collections decode leniently. Every response the server sends carries `tags`, `media`,
/// and `media_count` — but an entry that fails to decode because a list was absent is a card
/// that vanishes from the archive, and a card with no chips is not.
nonisolated struct EntryResponse: Decodable, Identifiable, Sendable {
    let id: UUID
    let childId: UUID
    let assignmentId: UUID?
    let occurredAt: Date
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let title: String?
    let body: String?
    let entryType: String?
    let childAgeMonths: Int?
    let unlockAtAge: Int?
    let tags: [TagResponse]
    let media: [MediaSummaryResponse]
    /// The server's count of live media. Equal to `media.count` today; read rather than derived
    /// so a future truncated list still renders an honest `+N`.
    let mediaCount: Int
    /// `GET /entries/{id}` only. Nil on a list row and nil for a freeform entry — the two are
    /// indistinguishable here on purpose, because neither renders a prompt block.
    let prompt: PromptRefResponse?

    private enum CodingKeys: String, CodingKey {
        case id, childId, assignmentId, occurredAt, createdAt, updatedAt, deletedAt
        case title, body, entryType, childAgeMonths, unlockAtAge, tags, media, mediaCount, prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        childId = try container.decode(UUID.self, forKey: .childId)
        assignmentId = try container.decodeIfPresent(UUID.self, forKey: .assignmentId)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        entryType = try container.decodeIfPresent(String.self, forKey: .entryType)
        childAgeMonths = try container.decodeIfPresent(Int.self, forKey: .childAgeMonths)
        unlockAtAge = try container.decodeIfPresent(Int.self, forKey: .unlockAtAge)
        tags = try container.decodeIfPresent([TagResponse].self, forKey: .tags) ?? []
        media = try container.decodeIfPresent([MediaSummaryResponse].self, forKey: .media) ?? []
        mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount) ?? media.count
        prompt = try container.decodeIfPresent(PromptRefResponse.self, forKey: .prompt)
    }
}
