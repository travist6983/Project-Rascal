import Foundation

/// The shared-container queue the share extension writes and the app drains.
///
/// **Written by the extension, read and emptied by the app.** The mirror image of
/// `WidgetSnapshotStore`, which the app writes and the widget only reads, and it lives in the
/// same App Group for the same reason there is one: a second group would be a second thing to get
/// right at signing time and a second thing to migrate.
///
/// Two subdirectories, and the split is what makes a crash survivable:
///
/// ```
/// <container>/
///   today.json              the widget's, untouched by anything here
///   share-inbox/
///     owner.json            which child the inbox belongs to, written by the app
///     records/<entry_id>.json
///     media/<media_id>.<ext>
/// ```
///
/// **Bytes first, record last, and the record is written atomically.** The drain only ever reads
/// records, so a share interrupted halfway leaves media files that no record names — collectable
/// by `sweepOrphans`, and never mistaken for work. The reverse order would let a record be found
/// pointing at a file that is still being written, which is how a truncated photo enters an
/// archive that is supposed to be permanent.
nonisolated struct ShareInbox: Sendable {

    /// **Must match `Rascal.entitlements`, `RascalWidget.entitlements` and
    /// `RascalShare.entitlements` exactly.**
    ///
    /// Duplicated from `WidgetSnapshotStore.appGroupIdentifier` rather than referenced, because
    /// that type is a widget concern and giving this extension the widget's snapshot model would
    /// hand a target that stages photos the whole shape of the Home Screen's state. The two
    /// constants are asserted equal in `ShareInboxTests`, so they cannot drift silently — the same
    /// arrangement `WidgetSnapshot.symbolName` has with `PromptKind.symbol`.
    static let appGroupIdentifier = "group.com.travisterry.childarchive"

    static let rootDirectoryName = "share-inbox"
    static let recordsDirectoryName = "records"
    static let mediaDirectoryName = "media"
    static let ownerFilename = "owner.json"

    /// Nil when the App Group container is unavailable. Not an error worth surfacing: it is what a
    /// build with entitlements stripped looks like, and CI builds exactly that with
    /// `CODE_SIGNING_ALLOWED=NO`. Every operation degrades to doing nothing, and the extension
    /// says so rather than pretending it saved.
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    /// The real container.
    ///
    /// **`static let`, not a computed property**, for the reason `WidgetSnapshotStore.shared` is
    /// one: `containerURL(forSecurityApplicationGroupIdentifier:)` hits the filesystem, the
    /// container cannot move while the process is alive, and this is read from a SwiftUI default
    /// property value that gets re-evaluated on every rebuild.
    static let shared = ShareInbox(
        directory: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: rootDirectoryName, directoryHint: .isDirectory)
    )

    enum Failure: Error, Equatable {
        /// No App Group container. Nothing can be staged, and saying so is better than a silent
        /// success that loses a photo.
        case unavailable
        case copyFailed
        case encodingFailed
    }

    // MARK: Paths

    var recordsDirectory: URL? {
        directory?.appending(path: Self.recordsDirectoryName, directoryHint: .isDirectory)
    }

    var mediaDirectory: URL? {
        directory?.appending(path: Self.mediaDirectoryName, directoryHint: .isDirectory)
    }

    var ownerURL: URL? {
        directory?.appending(path: Self.ownerFilename)
    }

    func recordURL(for id: UUID) -> URL? {
        recordsDirectory?.appending(path: "\(id.uuidString.lowercased()).json")
    }

    func mediaURL(for item: PendingShare.Item) -> URL? {
        mediaDirectory?.appending(path: item.filename)
    }

    /// The filename a media id and extension produce. One place, so the extension's write and the
    /// app's read cannot disagree about it.
    static func filename(for mediaId: UUID, ext: String) -> String {
        let cleaned = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return "\(mediaId.uuidString.lowercased()).\(cleaned.isEmpty ? "dat" : cleaned)"
    }

    // MARK: Whose inbox this is

    /// The child the app is signed in as, published for the extension to read.
    ///
    /// **The extension has no session and cannot get one.** It is a separate process with no
    /// token, no `GET /children` and twelve seconds to live; the App Group container is the only
    /// thing it can see. So the app writes down who it is and the extension stamps that into every
    /// record it stages — which is what stops a queue of photographs staged by one family being
    /// drained into another family's archive on a phone that changed hands.
    ///
    /// Versioned like everything else in this container. A marker this build cannot read resolves
    /// to *no owner*, which is the safe direction: shares are refused rather than misfiled.
    nonisolated struct Owner: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let childId: UUID

        init(version: Int = Owner.currentVersion, childId: UUID) {
            self.version = version
            self.childId = childId
        }
    }

    /// Record who the inbox belongs to. Called by the app — `ShareDrain` — and never by the
    /// extension, which is a reader here for the same reason the widget is a reader of the
    /// snapshot: two writers with no coordination is how a file starts disagreeing with itself.
    ///
    /// **`.completeFileProtectionUntilFirstUserAuthentication` for the reason the widget snapshot
    /// uses it**, and it matters more here: a marker that cannot be read is a share that cannot be
    /// claimed, and an unclaimable share is discarded. The file holds one opaque uuid, so the
    /// weaker class costs nothing.
    ///
    /// Failure is silent and reported by the return value. There is no user-facing recovery — the
    /// app's own work is unaffected — and the consequence is felt only in the extension, which
    /// says plainly that it cannot save.
    @discardableResult
    func publishOwner(_ childId: UUID) -> Bool {
        guard let ownerURL else { return false }
        guard let data = try? JSONEncoder().encode(Owner(childId: childId)) else { return false }
        do {
            try prepareDirectory()
            try data.write(
                to: ownerURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            return false
        }
    }

    /// Who the inbox belongs to, or nil when nobody has claimed it — no App Group, nobody signed
    /// in, or a marker written by a build that speaks a different version.
    func currentOwner() -> UUID? {
        guard let ownerURL,
              let data = try? Data(contentsOf: ownerURL),
              let owner = try? JSONDecoder().decode(Owner.self, from: data),
              owner.version == Owner.currentVersion
        else { return nil }
        return owner.childId
    }

    // MARK: Staging bytes

    struct Staged: Equatable, Sendable {
        let filename: String
        let byteCount: Int
    }

    /// Copy a shared file in, and report what landed.
    ///
    /// **A filesystem copy, never a read into memory.** `FileManager.copyItem` hands the work to
    /// the kernel, so peak memory does not move with the size of the file — which is the whole
    /// game in a share extension, where a hard memory ceiling and a 4K video are both routine.
    /// `NSItemProvider.loadDataRepresentation` would be the easy call here and it is the one that
    /// gets this process killed. `ShareInboxTests` measures the footprint across a large file
    /// rather than trusting this comment.
    ///
    /// **A copy, not a move**: the source belongs to the system, and it is gone the moment
    /// `completeRequest` returns — so this has to happen while the extension is still alive, and
    /// it must not disturb what PhotoKit still holds.
    ///
    /// Two steps, because a copy is not atomic. The bytes land under a dot-prefixed temporary name
    /// and are renamed into place, so a crash mid-copy cannot leave a half-file sitting under the
    /// name a record would eventually point at.
    ///
    /// **Nothing already staged is displaced until a complete replacement exists.** Media ids are
    /// fresh UUIDs, so a destination that already exists is not a case that can arise today — but
    /// clearing it up front would mean a copy that then failed had destroyed a good file to make
    /// room for one that never arrived, and that is not a thing to leave lying in a path whose
    /// whole job is holding the only copy of someone's photo.
    @discardableResult
    func stage(copyingFrom source: URL, as mediaId: UUID, ext: String) throws -> Staged {
        guard let mediaDirectory else { throw Failure.unavailable }
        try prepare()

        let name = Self.filename(for: mediaId, ext: ext)
        let destination = mediaDirectory.appending(path: name)
        let partial = mediaDirectory.appending(path: ".\(name).partial")

        try? FileManager.default.removeItem(at: partial)

        do {
            try FileManager.default.copyItem(at: source, to: partial)
            // `moveItem` refuses an occupied destination, so re-staging the same id needs the old
            // one out of the way — now, with the replacement already on disk, and not before.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.copyFailed
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
        return Staged(filename: name, byteCount: bytes ?? 0)
    }

    // MARK: The record

    /// Write the record that makes a set of staged files into a pending entry.
    ///
    /// **Last, and atomically.** `.atomic` stages the bytes beside the destination and renames
    /// over it, so the app — a separate process that is never asked to wait — reads either a whole
    /// record or no record. A partially written record must never be drained, and this is what
    /// guarantees it rather than a convention someone has to remember.
    ///
    /// **A record that arrives unbound is bound here**, to whoever the container currently names.
    /// The extension already stamps the owner it read when the share opened, and that stamp is
    /// never overwritten — this is the backstop that makes "a record reached disk unbound while the
    /// owner was known" a state no writer can produce by forgetting. With no owner published the
    /// record stays unbound, and `ShareDrain` discards it rather than guessing.
    func write(_ record: PendingShare) throws {
        guard let url = recordURL(for: record.id) else { throw Failure.unavailable }
        try prepare()
        var record = record
        if record.ownerChildId == nil, let owner = currentOwner() {
            record = record.bound(to: owner)
        }
        guard let data = try? JSONEncoder().encode(record) else { throw Failure.encodingFailed }
        try data.write(to: url, options: [.atomic])
    }

    /// Everything waiting, oldest share first.
    ///
    /// Oldest first so the archive fills in the order things were shared, matching
    /// `EntrySync.unsyncedDescriptor`.
    func pending() -> [PendingShare] {
        recordFiles()
            .compactMap(Self.decode(contentsOf:))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Records present on disk that this build cannot read.
    ///
    /// Surfaced rather than swallowed so the count is available to the device checklist — but
    /// deliberately **not** deleted. A record this build cannot read is almost always one a newer
    /// build wrote during an upgrade, and the app that can read it is the next launch away.
    func unreadableCount() -> Int {
        recordFiles().count { Self.decode(contentsOf: $0) == nil }
    }

    private func recordFiles() -> [URL] {
        guard let recordsDirectory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }
    }

    /// Decode one record, or nil.
    ///
    /// **The version is read before the record is.** Decoding the whole thing and then checking
    /// `version` works only while every future version is a superset of this one; a version that
    /// removes or retypes a field fails to decode first, and the failure would be indistinguishable
    /// from corruption. Probing for the version alone means a mismatch is *rejected* — knowingly,
    /// as a version this build does not speak — rather than misread or mistaken for a broken file.
    static func decode(contentsOf url: URL) -> PendingShare? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              probe.version == PendingShare.currentVersion
        else { return nil }
        return try? JSONDecoder().decode(PendingShare.self, from: data)
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    // MARK: Emptying

    /// Remove one share: its record, then its files.
    ///
    /// **Record first.** The record is what drives work, so a crash between the two leaves files
    /// that nothing references — collectable by `sweepOrphans` — rather than a record pointing at
    /// bytes that are gone. Called only once the entry is confirmed created server-side; see
    /// `ShareDrain.reap`.
    func remove(_ record: PendingShare) {
        if let url = recordURL(for: record.id) {
            try? FileManager.default.removeItem(at: url)
        }
        for item in record.media {
            guard let url = mediaURL(for: item) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Empty the inbox completely — every record, every staged file, and the owner marker.
    ///
    /// **This is the sign-out call**, and it is the counterpart to `WidgetSnapshotStore.clear`:
    /// what the widget must not keep showing after somebody leaves, the inbox must not keep holding
    /// for the next person to arrive. Without it a share staged by one family survives on the
    /// device, and the only thing standing between it and the next family's archive is the owner
    /// check in `ShareDrain` — one guard, on a permanent archive, is not enough.
    ///
    /// **The whole directory goes, not a loop over `pending()`.** A record this build cannot read
    /// is invisible to `pending()` but still names photographs sitting in `media/`, and leaving
    /// those behind is exactly the outcome this exists to prevent. Removing the owner marker too
    /// means anything staged before the next sign-in is unclaimed rather than inherited.
    ///
    /// Returns how many records were on disk. Nothing here recreates the directory — `prepare()`
    /// does that the next time something is staged.
    @discardableResult
    func clear() -> Int {
        guard let directory else { return 0 }
        let count = recordFiles().count
        try? FileManager.default.removeItem(at: directory)
        return count
    }

    /// Media files no surviving record names.
    ///
    /// A share that died between copying bytes and writing its record leaves these, and nothing
    /// else will ever pick them up. Returns how many were removed.
    ///
    /// **Guarded on the container being reachable**, because "no records" and "cannot see the
    /// records directory" are the same empty array from here, and the second one must not be read
    /// as permission to delete a parent's photos.
    @discardableResult
    func sweepOrphans() -> Int {
        guard let mediaDirectory, let recordsDirectory,
              FileManager.default.fileExists(atPath: recordsDirectory.path)
        else { return 0 }

        let named = Set(pending().flatMap { $0.media.map(\.filename) })
        // Records this build cannot read still name files, and their names are unreachable from
        // here. Refusing to sweep at all while one exists is the only safe reading: the
        // alternative deletes the media belonging to a record a newer build wrote.
        guard unreadableCount() == 0 else { return 0 }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        var removed = 0
        for url in files where !named.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    // MARK: Internals

    /// Both directories, and excluded from iCloud backup for the reason `StagingStore` is: these
    /// are transient copies of photos the library already holds, and backing them up would put a
    /// video into someone's iCloud quota twice.
    private func prepare() throws {
        guard let recordsDirectory, let mediaDirectory else { throw Failure.unavailable }
        try prepareDirectory()
        try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    }

    /// The root alone, for the owner marker — which the app publishes on every launch, including
    /// launches where nothing is ever staged. Creating `records/` and `media/` for it would leave
    /// an inbox that looks prepared for work nobody has asked for.
    private func prepareDirectory() throws {
        guard let directory else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(resource)
    }
}
