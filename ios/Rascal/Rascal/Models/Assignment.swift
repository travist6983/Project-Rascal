import Foundation
import SwiftData

/// A cached assignment row, mirroring the `assignments` table in `docs/data-model.md`.
///
/// **The server owns the schedule.** This is a cache of what the server said was assigned, kept
/// so `GET /sync` has somewhere to put the `assignments` array it returns. Nothing here decides
/// what was assigned, when it expires, or what day it is — those are server answers rendered in
/// the child's `family_timezone`.
///
/// Today still renders from a live `GET /today`, not from this. The row exists so a status change
/// made on another device converges locally rather than being dropped on the floor, and so the
/// dry-run report can say what a pull would do to it.
///
/// **No `deletedAt`, deliberately.** `SyncAssignment` on the wire carries no `deleted_at` field:
/// assignments are never soft-deleted server-side, they change `status` instead. A nullable column
/// here would be a local invention the server has no way to fill.
@Model
final class Assignment {
    /// Server-generated, unlike entries and media. An assignment is only ever created by the
    /// scheduler, so there is no offline-creation path that would need a client-minted id.
    @Attribute(.unique) var id: UUID

    var childId: UUID

    /// `question` · `mission` · `weekly` · `monthly` · `letter`. Text, for the same reason the
    /// server uses `text` + CHECK: a new slot must not require a migration.
    var slot: String
    /// The parent-authored `custom_body` where there is one, else the library prompt's.
    var body: String
    var kind: String
    var completionMode: String
    var theme: String?

    /// `pending` · `done` · `dismissed` · `expired`. Server-owned.
    var status: String

    /// Calendar days in the child's timezone, held as the server's `YYYY-MM-DD` strings rather
    /// than parsed into `Date`. They are days, not instants, and turning one into an instant
    /// picks a timezone the client does not get to pick.
    var assignedOn: String
    var expiresOn: String?

    var promptId: UUID?
    var isCustom: Bool = false
    var unlockAtAge: Int?

    /// Who completed it, when the server knows. Null on a pending row.
    var completedBy: UUID?

    /// Server-maintained by a trigger; sync filters and orders on it.
    var updatedAt: Date

    init(
        id: UUID,
        childId: UUID,
        slot: String,
        body: String,
        kind: String,
        completionMode: String,
        status: String,
        assignedOn: String,
        updatedAt: Date,
        theme: String? = nil,
        expiresOn: String? = nil,
        promptId: UUID? = nil,
        isCustom: Bool = false,
        unlockAtAge: Int? = nil,
        completedBy: UUID? = nil
    ) {
        self.id = id
        self.childId = childId
        self.slot = slot
        self.body = body
        self.kind = kind
        self.completionMode = completionMode
        self.status = status
        self.assignedOn = assignedOn
        self.updatedAt = updatedAt
        self.theme = theme
        self.expiresOn = expiresOn
        self.promptId = promptId
        self.isCustom = isCustom
        self.unlockAtAge = unlockAtAge
        self.completedBy = completedBy
    }

    var assignmentStatus: AssignmentStatus {
        get { AssignmentStatus(rawValue: status) }
        set { status = newValue.rawValue }
    }

    var slotKind: Slot { Slot(rawValue: slot) }
    var promptKind: PromptKind { PromptKind(rawValue: kind) }
    var completion: CompletionMode { CompletionMode(rawValue: completionMode) }

    var isDone: Bool { assignmentStatus == .done }

    /// Everything the server owns, written onto a cached row.
    ///
    /// A pure assignment of every field, which is what makes re-applying the same row a no-op —
    /// the overlap window guarantees rows arrive twice, so this has to be idempotent rather than
    /// merely tolerable.
    func apply(_ incoming: SyncAssignmentResponse) {
        childId = incoming.childId
        slot = incoming.slot
        body = incoming.body
        kind = incoming.kind
        completionMode = incoming.completionMode
        theme = incoming.theme
        status = incoming.status.rawValue
        assignedOn = incoming.assignedOn
        expiresOn = incoming.expiresOn
        promptId = incoming.promptId
        isCustom = incoming.isCustom
        unlockAtAge = incoming.unlockAtAge
        completedBy = incoming.completedBy
        updatedAt = incoming.updatedAt
    }

    /// Whether applying `incoming` would change anything at all.
    ///
    /// Compared field by field rather than by timestamp. The overlap window re-delivers rows
    /// whose `updated_at` is unchanged, and the honest answer for those is "unchanged", not
    /// "updated" — a dry-run report that counts thirty re-deliveries as thirty updates is a
    /// report that teaches the reader to distrust it.
    func differs(from incoming: SyncAssignmentResponse) -> Bool {
        childId != incoming.childId
            || slot != incoming.slot
            || body != incoming.body
            || kind != incoming.kind
            || completionMode != incoming.completionMode
            || theme != incoming.theme
            || status != incoming.status.rawValue
            || assignedOn != incoming.assignedOn
            || expiresOn != incoming.expiresOn
            || promptId != incoming.promptId
            || isCustom != incoming.isCustom
            || unlockAtAge != incoming.unlockAtAge
            || completedBy != incoming.completedBy
            || updatedAt != incoming.updatedAt
    }

    static func fromServer(_ incoming: SyncAssignmentResponse) -> Assignment {
        let assignment = Assignment(
            id: incoming.id,
            childId: incoming.childId,
            slot: incoming.slot,
            body: incoming.body,
            kind: incoming.kind,
            completionMode: incoming.completionMode,
            status: incoming.status.rawValue,
            assignedOn: incoming.assignedOn,
            updatedAt: incoming.updatedAt
        )
        assignment.apply(incoming)
        return assignment
    }
}
