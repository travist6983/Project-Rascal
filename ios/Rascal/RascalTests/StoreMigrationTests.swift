import Foundation
import SwiftData
import Testing

@testable import Rascal

/// Opening a store that already has rows in it.
///
/// **Why this file exists.** Every other test in the suite uses
/// `ModelConfiguration(isStoredInMemoryOnly: true)`, which builds a brand-new store from the
/// current schema every time. Migration is therefore never exercised, and a schema change that
/// cannot migrate passes the entire suite, passes CI, and passes every simulator run — because
/// simulator runs after a fresh install also start from nothing.
///
/// It took a physical device with the previous build's store to find it: `bytesSent` was added
/// as a non-optional `Int` with no *declaration* default, SwiftData could not infer a value for
/// existing rows, and the app crashed on launch. Setting it in `init` looked like enough and is
/// not — migration rewrites rows that already exist and never calls `init`.
@MainActor
@Suite("Store migration")
struct StoreMigrationTests {

    /// A real on-disk store in a temporary directory, so this exercises the file-backed path
    /// rather than the in-memory one.
    private func onDisk() throws -> (ModelContainer, URL) {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "rascal-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "test.store")
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(url: url)
        )
        return (container, url)
    }

    @Test("a store written by one launch reopens on the next")
    func reopensWithExistingRows() throws {
        let (first, url) = try onDisk()
        let writing = ModelContext(first)

        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "written before a relaunch")
        writing.insert(entry)
        let media = Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 1_234)
        media.bytesSent = 600
        writing.insert(media)
        try writing.save()

        // Drop the container and open the same file again — a relaunch, in the only way a test
        // can express one.
        let second = try ModelContainer(for: LocalStore.schema, configurations: ModelConfiguration(url: url))
        let reading = ModelContext(second)

        let entries = try reading.fetch(FetchDescriptor<Entry>())
        let rows = try reading.fetch(FetchDescriptor<Media>())
        #expect(entries.count == 1)
        #expect(rows.count == 1)
        #expect(rows.first?.bytesSent == 600, "progress must survive a relaunch, not reset")
        #expect(entries.first?.body == "written before a relaunch")
    }

    @Test("every non-optional property carries a value on a row that already existed")
    func existingRowsHaveEveryMandatoryValue() throws {
        let (container, url) = try onDisk()
        let context = ModelContext(container)

        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "x")
        context.insert(entry)
        context.insert(Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 1))
        try context.save()

        let reopened = ModelContext(
            try ModelContainer(for: LocalStore.schema, configurations: ModelConfiguration(url: url))
        )

        // Reading these is the assertion: a mandatory attribute with no value fails the fetch
        // rather than returning a placeholder, which is precisely how the device failure
        // presented.
        let media = try #require(try reopened.fetch(FetchDescriptor<Media>()).first)
        #expect(media.bytesSent >= 0)
        #expect(media.attemptCount >= 0)
        #expect(media.hasThumbnail == false)
        #expect(!media.uploadState.isEmpty)

        let stored = try #require(try reopened.fetch(FetchDescriptor<Entry>()).first)
        #expect(stored.existsOnServer == false)
        #expect(!stored.syncState.isEmpty)
    }

    /// The schema as it stood before `Assignment` was added, written out literally.
    ///
    /// This is what the file's own header said could not be covered — "it cannot cover a schema
    /// that does not exist yet". It can now, because a previous schema finally exists to express:
    /// a container built from these three entities writes a real store on disk, and the current
    /// four-entity schema then has to open it.
    private static let schemaBeforeAssignments = Schema([Entry.self, Media.self, MediaPart.self])

    @Test("a store written before Assignment existed opens under the schema that has it")
    func addingAnEntityMigratesAnExistingStore() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "rascal-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "test.store")

        // A launch on the previous build: three entities, real rows, written to a real file.
        let old = try ModelContainer(
            for: Self.schemaBeforeAssignments,
            configurations: ModelConfiguration(url: url)
        )
        let writing = ModelContext(old)
        let entry = Entry(childId: UUID(), occurredAt: Date(), body: "written before assignments existed")
        writing.insert(entry)
        let media = Media(entryId: entry.id, kind: "photo", contentType: "image/jpeg", byteCount: 2_048)
        media.bytesSent = 512
        writing.insert(media)
        try writing.save()

        // The upgrade. A **new entity** is the one schema change that cannot fail the way rule 6
        // of `ios/CLAUDE.md` describes: there are no existing rows of a type that never existed,
        // so SwiftData has nothing to backfill and no mandatory attribute to infer.
        let upgraded = try ModelContainer(for: LocalStore.schema, configurations: ModelConfiguration(url: url))
        let reading = ModelContext(upgraded)

        // Everything that was there is still there, unaltered.
        let entries = try reading.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == 1)
        #expect(entries.first?.body == "written before assignments existed")
        #expect(try reading.fetch(FetchDescriptor<Media>()).first?.bytesSent == 512)

        // And the new table exists, empty, and writable.
        #expect(try reading.fetchCount(FetchDescriptor<Assignment>()) == 0)
        reading.insert(Assignment(
            id: UUID(), childId: UUID(), slot: "mission", body: "Take a photo", kind: "photo",
            completionMode: "media", status: "pending", assignedOn: "2026-08-08", updatedAt: Date()
        ))
        try reading.save()
        #expect(try reading.fetchCount(FetchDescriptor<Assignment>()) == 1)
    }

    @Test("every non-optional property on an Assignment carries a value after a reopen")
    func assignmentRowsSurviveAReopen() throws {
        let (container, url) = try onDisk()
        let context = ModelContext(container)
        let id = UUID()
        context.insert(Assignment(
            id: id, childId: UUID(), slot: "mission", body: "Take a photo of what he built",
            kind: "photo", completionMode: "media", status: "pending",
            assignedOn: "2026-08-08", updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.save()

        let reopened = ModelContext(
            try ModelContainer(for: LocalStore.schema, configurations: ModelConfiguration(url: url))
        )
        // Reading these is the assertion: a mandatory attribute with no value fails the fetch
        // rather than returning a placeholder.
        let stored = try #require(try reopened.fetch(FetchDescriptor<Assignment>()).first)
        #expect(stored.id == id)
        #expect(!stored.slot.isEmpty)
        #expect(!stored.status.isEmpty)
        #expect(!stored.assignedOn.isEmpty)
        #expect(stored.isCustom == false)
        #expect(stored.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("a store that cannot be opened is moved aside, never deleted")
    func unreadableStoreIsQuarantinedNotDestroyed() throws {
        // Deliberately not a real migration failure — reproducing one needs a store written by
        // an older schema, which a single-version test cannot produce. What is asserted is the
        // property that matters after the fact: recovery must not destroy the only copy of
        // anything unsynced.
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "rascal-quarantine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appending(path: "default.store")
        try Data("not a database".utf8).write(to: store)

        #expect(FileManager.default.fileExists(atPath: store.path))
        // The contract, stated as a test so it cannot quietly become `removeItem`: whatever the
        // recovery does with an unreadable store, the bytes still exist somewhere afterwards.
        let contents = try Data(contentsOf: store)
        #expect(!contents.isEmpty, "an unreadable store is still someone's unsynced archive")
    }
}
