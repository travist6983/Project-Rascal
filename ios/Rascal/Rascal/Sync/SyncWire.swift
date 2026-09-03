import Foundation

/// The wire shape of `GET /v1/sync`, mirroring `api/src/rascal/schemas/sync.py`.
///
/// Deliberately separate from the SwiftData models, for the same reason `TodayResponse` and the
/// timeline shapes are: the API shape and the local cache shape are different concerns and will
/// drift, and collapsing them means every server change becomes a migration.
///
/// **Every entity here can arrive soft-deleted.** `/sync` is the one endpoint that returns rows
/// with `deleted_at` set, because a client cannot infer a deletion from a missing record. A type
/// in this file that drops `deleted_at` would silently turn every remote deletion into a no-op.

// MARK: - The response

nonisolated struct SyncPullResponse: Decodable, Sendable {
    let entries: [EntryResponse]
    let media: [SyncMediaResponse]
    let assignments: [SyncAssignmentResponse]
    let tags: [SyncTagResponse]
    /// Feed this back as `since` on the next call. **Deliberately lagged** by the server's
    /// overlap window — see `SyncEngine.overlapWindow`.
    let cursor: Date

    /// **True while any of the four collections was cut at the page bound.** The pull is not
    /// finished until this is false — see `SyncEngine.execute` for what a stalled cursor means
    /// while it is true. A server predating the field sent the whole delta in one response, so
    /// absent reads as false.
    let hasMore: Bool

    /// Keys the client does not model, so the dry-run report can say "12 records I did not
    /// understand" instead of dropping them silently.
    ///
    /// A future server release adding a fifth entity type is the case this exists for. The
    /// client cannot apply it, but staying quiet about it is how a whole category of records
    /// goes missing without anyone noticing for a year.
    let unrecognisedKeys: [String]

    /// Everything this response could carry that this client knows how to apply.
    /// `hasMore` rather than `has_more`: the decoder converts from snake case before these keys
    /// are read, so the unrecognised-key check sees the converted spelling.
    static let knownKeys: Set<String> = ["entries", "media", "assignments", "tags", "cursor", "hasMore"]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum CodingKeys: String, CodingKey {
        case entries, media, assignments, tags, cursor, hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Lenient on the collections, strict on the cursor. A missing array is an empty batch
        // and the pull carries on; a missing cursor means there is no safe position to store,
        // and guessing one is how a client skips records permanently.
        entries = try container.decodeIfPresent([EntryResponse].self, forKey: .entries) ?? []
        media = try container.decodeIfPresent([SyncMediaResponse].self, forKey: .media) ?? []
        assignments = try container
            .decodeIfPresent([SyncAssignmentResponse].self, forKey: .assignments) ?? []
        tags = try container.decodeIfPresent([SyncTagResponse].self, forKey: .tags) ?? []
        cursor = try container.decode(Date.self, forKey: .cursor)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false

        let all = try decoder.container(keyedBy: AnyKey.self)
        unrecognisedKeys = all.allKeys
            .map(\.stringValue)
            .filter { !Self.knownKeys.contains($0) }
            .sorted()
    }

    var recordCount: Int {
        entries.count + media.count + assignments.count + tags.count
    }

    var isEmpty: Bool { recordCount == 0 }
}

// MARK: - Media

/// `MediaOut` — a `MediaDetail` plus `entry_id` and `deleted_at`.
///
/// Distinct from `MediaSummaryResponse`, which is the shape inlined into an entry. Two fields
/// make the difference and both matter here: an entry's inline media list is **live only**, so it
/// can never carry a deletion, and it has no `entry_id` because the entry is the context. A sync
/// media row has neither luxury.
nonisolated struct SyncMediaResponse: Decodable, Identifiable, Sendable {
    let id: UUID
    let entryId: UUID
    let kind: String
    let s3Key: String
    /// Null on every row today — thumbnail generation was cut from P0.
    let thumbKey: String?
    let durationSeconds: Int?
    let bytes: Int
    let uploadStatus: String
    let capturedAt: Date?
    let transcript: String?
    let caption: String?
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    var mediaKind: PromptKind { PromptKind(rawValue: kind) }

    /// The server has the bytes. Anything else has nothing this phone can render.
    var isComplete: Bool { MediaUploadState(rawValue: uploadStatus) == .complete }

    /// The same shape an entry inlines, so the existing `applyServerSummary` path is reused
    /// rather than forked. Everything a summary carries is a subset of this.
    var asSummary: MediaSummaryResponse {
        MediaSummaryResponse(
            id: id,
            kind: kind,
            s3Key: s3Key,
            thumbKey: thumbKey,
            durationSeconds: durationSeconds,
            bytes: bytes,
            uploadStatus: uploadStatus,
            capturedAt: capturedAt,
            transcript: transcript,
            caption: caption
        )
    }
}

// MARK: - Assignments

/// `SyncAssignment` — an `AssignmentOut` plus `child_id`, `updated_at`, and `completed_by`.
///
/// **There is no `deleted_at`.** Assignments are never soft-deleted server-side; they change
/// `status` instead. Anything in this client that treats an absent assignment as a deleted one is
/// wrong for that reason, not merely unsupported.
nonisolated struct SyncAssignmentResponse: Decodable, Identifiable, Sendable {
    let id: UUID
    let childId: UUID
    let slot: String
    let body: String
    let kind: String
    let completionMode: String
    let theme: String?
    let status: AssignmentStatus
    let assignedOn: String
    let expiresOn: String?
    let promptId: UUID?
    let isCustom: Bool
    let unlockAtAge: Int?
    let completedBy: UUID?
    let updatedAt: Date
}

// MARK: - Tags

/// `SyncTag` — an entry-tag **link**, with the tag's name inlined.
///
/// The link is the thing that changes. A bare tag list would not tell a client which entry lost
/// which tag, which is the whole reason the server sends links rather than tags.
nonisolated struct SyncTagResponse: Decodable, Sendable {
    let entryId: UUID
    let tagId: UUID
    let name: String
    /// `user` or `device_ai`.
    let source: String
    let updatedAt: Date
    let deletedAt: Date?

    var isRemoved: Bool { deletedAt != nil }
}
