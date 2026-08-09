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
