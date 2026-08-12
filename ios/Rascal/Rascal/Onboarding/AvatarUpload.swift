import Foundation

/// An avatar that exists on this phone and has not reached the server yet.
///
/// ## Why this is its own piece of state
///
/// The two existing queues were both considered and neither fits:
///
/// - **The entry queue** (`EntrySync.unsyncedDescriptor`) drains `Entry` rows by `syncState`. An
///   avatar is not an entry and must never become one — filing a picture of the child in the
///   archive as an entry's artifact is the exact outcome `services/avatars.py` was written to
///   avoid.
/// - **The media queue** (`MediaCoordinator`) drains `Media` rows, and every one of them is gated
///   on its entry existing server-side first, because `POST /media/upload-url` needs an `entry_id`
///   it recognises. An avatar hangs off a *child*, and `POST /children/{id}/avatar-upload-url`
///   needs only a child that by definition already exists. There is nothing for it to wait behind.
///
/// So it gets its own record, **modelled the same way as a media row**: the durable facts needed
/// to retry, plus `attemptCount` and `nextAttemptAt` driving the same `UploadBackoff` arithmetic.
/// It is drained by the same sweep, in the same pass. What it is *not* is a second retry loop with
/// its own policy — the schedule and the ceiling are shared.
///
/// ## Why `UserDefaults` rather than SwiftData
///
/// Everything else with a `nextAttemptAt` is a SwiftData row, so this is the odd one out and the
/// reason is worth stating rather than discovering later.
///
/// `AppEnvironment.schema` is a plain `Schema([Entry, Media, MediaPart, Assignment])` — **no
/// `VersionedSchema` and no `SchemaMigrationPlan`**, only a recovery path that rebuilds the store
/// when it cannot be opened. Adding a `@Model` to that schema changes the store on every existing
/// install, and this repo has already shipped one fix for exactly that failure ("the app could not
/// launch on any device that had the previous build"). Risking the launch path of every phone on
/// TestFlight to hold at most one small row per child is not a trade worth making.
///
/// The bytes are not here in any case: they are already on disk in `LocalAvatarStore`, which is
/// backed up and survives a relaunch. This record only says *that* they are owed to the server and
/// *how* to send them, which is a handful of scalars — the same thing `OnboardingDraft` and the
/// Apple user ID already keep in `UserDefaults`.
nonisolated struct PendingAvatarUpload: Codable, Equatable, Sendable {
    let childId: UUID

    /// **The exact string to presign for and then to send on the PUT.**
    ///
    /// Stored rather than assumed, even though `AvatarCrop` only ever produces JPEG today. The
    /// signature covers `content-type`, so the two have to be the same string, and the way that
    /// breaks is someone widening the crop to pass HEIC through and the PUT still announcing
    /// `image/jpeg` — a 403 that mentions signatures and never mentions the header.
    let contentType: String

    /// What the presign was asked to authorise. The server refuses ≤ 0 or > 5 MiB.
    let byteCount: Int

    /// Failed attempts so far. Feeds `UploadBackoff`, which is shared with media rather than
    /// reimplemented.
    var attemptCount: Int = 0

    /// When this becomes eligible again. `nil` means "never attempted", which is due immediately.
    var nextAttemptAt: Date?

    /// Past `UploadBackoff.maxAttempts` this stops being retried automatically.
    ///
    /// **It is not discarded.** The local copy is untouched and the record stays, so a later
    /// deliberate retry has everything it needs. What stops is the automatic sweep spending a
    /// request on it every time the app foregrounds.
    var isExhausted: Bool { attemptCount >= UploadBackoff.maxAttempts }
}

/// Where pending uploads live between launches.
///
/// Keyed by child rather than held as a single value. Multi-kid is out of scope for the *interface*
/// and this does not build any of it — but a store that can only remember one child would silently
/// drop the second one's avatar the day a switcher does exist, and a dictionary costs nothing now.
nonisolated protocol PendingAvatarUploadStoring: Sendable {
    func all() -> [UUID: PendingAvatarUpload]
    func save(_ pending: PendingAvatarUpload)
    func clear(for childId: UUID)
}

extension PendingAvatarUploadStoring {
    func pending(for childId: UUID) -> PendingAvatarUpload? { all()[childId] }
}

nonisolated final class UserDefaultsPendingAvatarUploadStore: PendingAvatarUploadStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "avatar.pendingUploads") {
        self.defaults = defaults
        self.key = key
    }

    func all() -> [UUID: PendingAvatarUpload] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([UUID: PendingAvatarUpload].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ pending: PendingAvatarUpload) {
        var current = all()
        current[pending.childId] = pending
        write(current)
    }

    func clear(for childId: UUID) {
        var current = all()
        guard current.removeValue(forKey: childId) != nil else { return }
        write(current)
    }

    /// A record that cannot be encoded is dropped rather than left half-written. The bytes are
    /// still on disk either way, so the worst case is an avatar that stays device-only — which is
    /// exactly where it was before this phase.
    private func write(_ records: [UUID: PendingAvatarUpload]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

nonisolated final class InMemoryPendingAvatarUploadStore: PendingAvatarUploadStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: PendingAvatarUpload] = [:]

    init(_ initial: [UUID: PendingAvatarUpload] = [:]) {
        records = initial
    }

    func all() -> [UUID: PendingAvatarUpload] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    func save(_ pending: PendingAvatarUpload) {
        lock.lock(); defer { lock.unlock() }
        records[pending.childId] = pending
    }

    func clear(for childId: UUID) {
        lock.lock(); defer { lock.unlock() }
        records[childId] = nil
    }
}
