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

    /// `pending` · `synced` · `failed`. Stored as text for the same reason the server uses
    /// `text` + CHECK: a new state must not require a migration.
    var syncState: String

    /// Stable across retries so a replay is recognised as the same write rather than a second
    /// row. Generated once, at creation.
    var idempotencyKey: UUID

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

    var type: EntryType? {
        entryType.map(EntryType.init(rawValue:))
    }

    var isDeleted: Bool { deletedAt != nil }

    /// The one place server truth is written back onto a local row.
    func applyServerResponse(_ response: EntryResponse) {
        entryType = response.entryType
        childAgeMonths = response.childAgeMonths
        updatedAt = response.updatedAt
        deletedAt = response.deletedAt
        sync = .synced
    }
}

enum SyncState: RawRepresentable, Equatable, Sendable {
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
enum EntryType: RawRepresentable, Equatable, Sendable {
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
struct EntryCreateRequest: Encodable {
    let id: UUID
    let childId: UUID
    let assignmentId: UUID?
    let occurredAt: Date
    let title: String?
    let body: String?
    let unlockAtAge: Int?
    let tags: [String]
}

struct EntryResponse: Decodable, Identifiable {
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
}
