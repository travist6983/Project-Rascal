import Foundation

@testable import Rascal

/// Server-shaped JSON, built the way the API builds it.
///
/// Free functions rather than methods on a suite: the stub performer's closures are `@Sendable`
/// and cannot reach an isolated helper, and both the data tests and the view tests need the same
/// shapes. Hand-written fixtures drift, so these mirror `api/src/rascal/schemas/entry.py`
/// field for field — if the two disagree, that file is right and this one is the bug.

/// One `EntryOut`, or `EntryDetail` when `prompt` is given.
func entryJSON(
    id: UUID,
    childId: UUID,
    occurredAt: Date,
    createdAt: Date? = nil,
    type: String = "text",
    body: String? = "he called it a hangaburger",
    title: String? = nil,
    ageMonths: Int = 62,
    unlockAtAge: Int? = nil,
    assignmentId: UUID? = nil,
    tags: [String] = [],
    media: [String] = [],
    prompt: String? = nil,
    updatedAt: Date? = nil,
    deletedAt: Date? = nil
) -> String {
    let occurred = ISO8601Formatters.string(from: occurredAt)
    let created = ISO8601Formatters.string(from: createdAt ?? occurredAt)
    // Defaults to `created_at` so every existing caller is unchanged. Sync filters on this and
    // on nothing else, so the two have to be separable the moment `/sync` is in the picture.
    let updated = ISO8601Formatters.string(from: updatedAt ?? createdAt ?? occurredAt)
    let deleted = deletedAt.map { "\"\(ISO8601Formatters.string(from: $0))\"" } ?? "null"
    let tagJSON = tags.map {
        #"{"id":"\#(UUID().uuidString)","name":"\#($0)","source":"user"}"#
    }.joined(separator: ",")
    let promptJSON = prompt.map {
        #""prompt":{"id":"\#(UUID().uuidString)","kind":"photo","cadence":"daily","completion_mode":"media","body":"\#($0)","theme":"everyday"},"#
    } ?? ""
    return """
    {"id":"\(id.uuidString)","child_id":"\(childId.uuidString)",
     "assignment_id":\(assignmentId.map { "\"\($0.uuidString)\"" } ?? "null"),
     "author_id":"\(UUID().uuidString)",
     "occurred_at":"\(occurred)","created_at":"\(created)","updated_at":"\(updated)",
     "deleted_at":\(deleted),"title":\(title.map { "\"\($0)\"" } ?? "null"),
     "body":\(body.map { "\"\($0)\"" } ?? "null"),
     "entry_type":"\(type)","child_age_months":\(ageMonths),
     "unlock_at_age":\(unlockAtAge.map(String.init) ?? "null"),
     \(promptJSON)
     "tags":[\(tagJSON)],"media":[\(media.joined(separator: ","))],
     "media_count":\(media.count)}
    """
}

/// One `MediaSummary`, or `MediaDetail` when `transcript` is given. `thumb_key` is null because
/// it is null on every row the server has ever returned — that pipeline was cut from P0.
func mediaJSON(
    id: UUID = UUID(),
    kind: String = "photo",
    status: String = "complete",
    bytes: Int = 120_000,
    duration: Int? = nil,
    transcript: String? = nil
) -> String {
    """
    {"id":"\(id.uuidString)","kind":"\(kind)","s3_key":"children/x/\(id.uuidString).jpg",
     "thumb_key":null,"duration_seconds":\(duration.map(String.init) ?? "null"),
     "bytes":\(bytes),"upload_status":"\(status)","captured_at":null,
     "transcript":\(transcript.map { "\"\($0)\"" } ?? "null"),"caption":null}
    """
}

func pageJSON(_ entries: [String], cursor: String?) -> Data {
    Data("""
    {"entries":[\(entries.joined(separator: ","))],
     "next_cursor":\(cursor.map { "\"\($0)\"" } ?? "null")}
    """.utf8)
}

func decodeEntry(_ json: String) throws -> EntryResponse {
    try APIClient.decoder.decode(EntryResponse.self, from: Data(json.utf8))
}

/// A cached entry carrying server truth, which is the only way `entry_type` and
/// `child_age_months` can be set — both are `private(set)` and written solely from a response,
/// because the client does not get to decide either one.
@MainActor
func cachedEntry(
    childId: UUID = UUID(),
    occurredAt: Date = Date(),
    type: String = "text",
    body: String? = "he called it a hangaburger",
    title: String? = nil,
    ageMonths: Int = 62,
    unlockAtAge: Int? = nil,
    tags: [String] = [],
    mediaCount: Int = 0,
    id: UUID = UUID(),
    updatedAt: Date? = nil
) throws -> Entry {
    let media = (0..<mediaCount).map { _ in mediaJSON() }
    let response = try decodeEntry(entryJSON(
        id: id, childId: childId, occurredAt: occurredAt, type: type,
        body: body, title: title, ageMonths: ageMonths, unlockAtAge: unlockAtAge,
        tags: tags, media: media, updatedAt: updatedAt
    ))
    let entry = Entry(
        id: id, childId: childId, occurredAt: occurredAt,
        title: title, body: body, unlockAtAge: unlockAtAge
    )
    entry.applyServerTruth(response)
    return entry
}

/// A `Media` row in the state a completed upload leaves it in.
@MainActor
func completeMedia(entryId: UUID, kind: String = "photo", duration: Int? = nil, transcript: String? = nil) -> Media {
    let media = Media(
        entryId: entryId,
        kind: kind,
        contentType: PromptKind(rawValue: kind).archiveContentType,
        byteCount: 1_000,
        durationSeconds: duration
    )
    media.state = .complete
    media.transcript = transcript
    return media
}
