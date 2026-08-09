import Foundation

@testable import Rascal

/// `GET /v1/sync` shaped JSON, built the way the API builds it.
///
/// Mirrors `api/src/rascal/schemas/sync.py` field for field — if the two disagree, that file is
/// right and this one is the bug. Free functions rather than methods on a suite, for the same
/// reason `TimelineFixtures` uses them: the stub performer's closures are `@Sendable` and cannot
/// reach an isolated helper.

/// One `MediaOut` — a `MediaDetail` plus `entry_id` and `deleted_at`.
///
/// Distinct from `mediaJSON`, which is the summary an entry inlines. The two extra fields are
/// exactly the ones sync needs: an entry's inline list is live-only and has no `entry_id`.
func syncMediaJSON(
    id: UUID = UUID(),
    entryId: UUID,
    kind: String = "photo",
    status: String = "complete",
    bytes: Int = 120_000,
    duration: Int? = nil,
    transcript: String? = nil,
    caption: String? = nil,
    s3Key: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    deletedAt: Date? = nil
) -> String {
    let created = ISO8601Formatters.string(from: createdAt)
    let updated = ISO8601Formatters.string(from: updatedAt)
    let deleted = deletedAt.map { "\"\(ISO8601Formatters.string(from: $0))\"" } ?? "null"
    return """
    {"id":"\(id.uuidString)","entry_id":"\(entryId.uuidString)","kind":"\(kind)",
     "s3_key":"\(s3Key ?? "children/x/\(id.uuidString).jpg")","thumb_key":null,
     "duration_seconds":\(duration.map(String.init) ?? "null"),"bytes":\(bytes),
     "upload_status":"\(status)","captured_at":null,
     "transcript":\(transcript.map { "\"\($0)\"" } ?? "null"),
     "caption":\(caption.map { "\"\($0)\"" } ?? "null"),
     "created_at":"\(created)","updated_at":"\(updated)","deleted_at":\(deleted)}
    """
}

/// One `SyncAssignment` — an `AssignmentOut` plus `child_id`, `updated_at`, `completed_by`.
///
/// **No `deleted_at`, and that is not an omission.** Assignments are never soft-deleted
/// server-side; they change `status` instead.
func syncAssignmentJSON(
    id: UUID = UUID(),
    childId: UUID,
    slot: String = "mission",
    body: String = "Take a photo of what he built",
    kind: String = "photo",
    completionMode: String = "media",
    theme: String? = "everyday",
    status: String = "pending",
    assignedOn: String = "2026-08-08",
    expiresOn: String? = "2026-08-22",
    promptId: UUID? = nil,
    isCustom: Bool = false,
    unlockAtAge: Int? = nil,
    completedBy: UUID? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> String {
    """
    {"id":"\(id.uuidString)","child_id":"\(childId.uuidString)","slot":"\(slot)",
     "body":"\(body)","kind":"\(kind)","completion_mode":"\(completionMode)",
     "theme":\(theme.map { "\"\($0)\"" } ?? "null"),"status":"\(status)",
     "assigned_on":"\(assignedOn)","expires_on":\(expiresOn.map { "\"\($0)\"" } ?? "null"),
     "prompt_id":\(promptId.map { "\"\($0.uuidString)\"" } ?? "null"),
     "is_custom":\(isCustom),"unlock_at_age":\(unlockAtAge.map(String.init) ?? "null"),
     "completed_by":\(completedBy.map { "\"\($0.uuidString)\"" } ?? "null"),
     "updated_at":"\(ISO8601Formatters.string(from: updatedAt))"}
    """
}

/// One `SyncTag` — the entry-tag **link**, with the tag's name inlined.
func syncTagJSON(
    entryId: UUID,
    tagId: UUID = UUID(),
    name: String = "humor",
    source: String = "user",
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    deletedAt: Date? = nil
) -> String {
    let deleted = deletedAt.map { "\"\(ISO8601Formatters.string(from: $0))\"" } ?? "null"
    return """
    {"entry_id":"\(entryId.uuidString)","tag_id":"\(tagId.uuidString)","name":"\(name)",
     "source":"\(source)","updated_at":"\(ISO8601Formatters.string(from: updatedAt))",
     "deleted_at":\(deleted)}
    """
}

/// A whole `SyncResponse`.
///
/// `extraKeys` exists to exercise the anomaly path: a future server release adding a fifth
/// entity type must be reported loudly, not dropped on the floor.
func syncJSON(
    entries: [String] = [],
    media: [String] = [],
    assignments: [String] = [],
    tags: [String] = [],
    cursor: Date,
    extraKeys: [String: String] = [:]
) -> Data {
    let extras = extraKeys.isEmpty
        ? ""
        : extraKeys.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + ","
    return Data("""
    {\(extras)"entries":[\(entries.joined(separator: ","))],
     "media":[\(media.joined(separator: ","))],
     "assignments":[\(assignments.joined(separator: ","))],
     "tags":[\(tags.joined(separator: ","))],
     "cursor":"\(ISO8601Formatters.string(from: cursor))"}
    """.utf8)
}

/// The cursor the server would hand back for a set of rows: the newest `updated_at`, lagged by
/// the overlap window. Mirrors `service.pull` so a test's arithmetic and the server's agree.
func laggedCursor(newest: Date) -> Date {
    newest.addingTimeInterval(-SyncEngine.overlapWindow)
}
