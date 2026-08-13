import Foundation
import Testing

@testable import Rascal

/// The archive export — the row that, per its own header, makes the product's promise checkable.
///
/// What is asserted here is the part a header from the network reaches: the filename the zip is
/// saved under. `Content-Disposition` is server-supplied text, it is used to build a path, and a
/// value carrying `/` or `..` would write outside the exports directory the download was handed.
/// The guard against that is one line in `ArchiveExport.filename(from:childId:)`, and until this
/// file existed nothing checked it.
///
/// **The download itself is not reachable from here, and no test below pretends otherwise.**
/// `ArchiveExport.download(childId:api:downloader:)` is `private`, so `@testable` does not open it,
/// and `ArchiveDownloader` builds its own `URLSession` with no seam for a stub protocol — so the
/// 401-refresh-and-retry and the non-2xx envelope decode cannot be driven without a network. They
/// stay uncovered rather than covered by something that only looks like a test.
@MainActor
@Suite("Archive export", .serialized)
struct ArchiveExportTests {

    private let childId = UUID(uuidString: "1F0E4D9C-6B2A-4C8E-9A31-7D5E2B0C4A16")!

    /// Force-unwrapped for the reason `RefreshTests` does the same: `HTTPURLResponse` is optional
    /// only for a malformed URL, and this one is a literal.
    private func response(disposition: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.rascal.app/v1/children/x/export")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: disposition.map { ["Content-Disposition": $0] }
        )!
    }

    /// What the server actually sends. Parsed rather than reinvented so the file a parent saves is
    /// named the same in the share sheet as it is in the archive.
    @Test("the server's own filename is used, quoted or bare")
    func theServersNameIsUsed() {
        let quoted = ArchiveExport.filename(
            from: response(disposition: #"attachment; filename="rascal-miles-20260809.zip""#),
            childId: childId
        )
        #expect(quoted == "rascal-miles-20260809.zip")

        let bare = ArchiveExport.filename(
            from: response(disposition: "attachment; filename=rascal-miles-20260809.zip"),
            childId: childId
        )
        #expect(bare == "rascal-miles-20260809.zip")
    }

    /// HTTP header names are case-insensitive and the server spells this one `Content-Disposition`,
    /// while the client looks it up lowercased. If that lookup were ever case-sensitive every export
    /// would silently take the fallback name instead — a bug nothing else would report.
    @Test("the header is found however the server capitalises it")
    func theLookupIsCaseInsensitive() {
        let name = ArchiveExport.filename(
            from: response(disposition: #"attachment; filename="rascal-ada-20260812.zip""#),
            childId: childId
        )
        #expect(name == "rascal-ada-20260812.zip")
    }

    /// No header, so the client names the file itself. Still one file per child, still a zip.
    @Test("a response with no disposition falls back to a generated name")
    func aMissingHeaderFallsBack() {
        let name = ArchiveExport.filename(from: response(), childId: childId)

        #expect(name.hasPrefix("rascal-archive-"))
        #expect(name.hasSuffix(".zip"))
        #expect(name.contains(String(childId.uuidString.prefix(8))),
                "the name says which archive it is")
        #expect(!name.contains("/"))
    }

    /// **The guard that matters.** A header is not a path, and the server is not the only thing
    /// that can put one in a header. Every one of these must produce the same name as no header at
    /// all — never a traversal, never a partial parse of one.
    @Test(
        "a disposition carrying a path separator is refused",
        arguments: [
            #"attachment; filename="../../../Library/Preferences/rascal.zip""#,
            #"attachment; filename="/etc/passwd""#,
            #"attachment; filename="nested/rascal.zip""#,
            #"attachment; filename="..""#,
            #"attachment; filename="""#,
            "attachment; filename=",
            // No `filename=` token at all: the extended RFC 5987 form is not parsed, and falling
            // back is the safe reading of a header this client does not understand.
            "attachment; filename*=UTF-8''rascal-miles.zip",
            "attachment",
        ]
    )
    func anAdversarialDispositionIsRefused(_ disposition: String) {
        let fallback = ArchiveExport.filename(from: response(), childId: childId)
        let name = ArchiveExport.filename(
            from: response(disposition: disposition), childId: childId
        )

        #expect(name == fallback, "a header that is not a plain filename gets the generated name")
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
    }

    /// The property the guard exists to hold, stated as the delegate uses it: whatever the header
    /// said, the destination is inside the exports directory.
    @Test("the destination stays inside the exports directory")
    func theDestinationCannotEscape() throws {
        let folder = try ArchiveExport.exportsFolder().standardizedFileURL

        for disposition in [
            #"attachment; filename="../../../Library/Preferences/rascal.zip""#,
            #"attachment; filename="/etc/passwd""#,
            #"attachment; filename="rascal-miles-20260809.zip""#,
        ] {
            let destination = folder
                .appending(path: ArchiveExport.filename(
                    from: response(disposition: disposition), childId: childId
                ))
                .standardizedFileURL

            #expect(destination.deletingLastPathComponent().standardizedFileURL.path == folder.path,
                    "\(disposition) resolved to \(destination.path)")
        }
    }

    // MARK: - The directory itself

    /// `Caches`, because the zip is a third copy of data that already exists on the server and in
    /// the local store — the system is welcome to reclaim it.
    @Test("the exports directory is created under Caches")
    func theFolderIsUnderCaches() throws {
        let folder = try ArchiveExport.exportsFolder()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
        #expect(folder.standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path))
        #expect(folder.lastPathComponent == "exports")
    }

    /// Orphans are easy to make and impossible to notice — leaving the tab mid-download tears down
    /// the view while the task keeps running, and a force quit between the move and the share leaves
    /// a finished zip nobody will ever open. Hundreds of megabytes of a third copy is not something
    /// to leave waiting for memory pressure.
    @Test("purging clears the directory and is safe to repeat")
    func purgingClearsOrphans() throws {
        let folder = try ArchiveExport.exportsFolder()
        let orphan = folder.appending(path: "rascal-orphan-\(UUID().uuidString).zip")
        try Data("half an archive".utf8).write(to: orphan)
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        ArchiveExport.purgeStale()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )
        #expect(contents.isEmpty)

        // Called on every appearance of the screen, so the empty case has to be a no-op rather
        // than an error.
        ArchiveExport.purgeStale()
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }
}
