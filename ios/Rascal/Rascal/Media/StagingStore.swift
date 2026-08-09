import Foundation

/// Where picked and captured files live between selection and a finished upload.
///
/// PHPicker and the camera hand back URLs into a temporary container that the system may empty
/// at any point. An upload that survives a force quit can reach the file minutes or hours
/// later, so the bytes are copied here **before anything else happens** — before the entry is
/// saved, before any request goes out.
///
/// Everything is addressed by `media_id`, and the path is recorded in SwiftData rather than
/// held in memory. After a force quit the uploader reconstructs its work from disk state alone.
nonisolated struct StagingStore {
    /// `Application Support` rather than `Caches`: the system may purge Caches under pressure,
    /// and this holds the only copy of a photo until the upload completes.
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot()
        try? Self.prepare(self.root)
    }

    private static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "staging", directoryHint: .isDirectory)
    }

    /// Excluded from iCloud backup: these are transient copies of photos the library already
    /// holds, and backing them up would duplicate a video into someone's iCloud quota.
    private static func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(resource)
    }

    // MARK: Paths

    func originalURL(for mediaId: UUID, ext: String) -> URL {
        root.appending(path: "\(mediaId.uuidString.lowercased()).\(normalized(ext))")
    }

    /// Thumbnails sit beside the originals and outlive them: the original is deleted once
    /// uploaded, the thumbnail stays so the timeline renders without refetching.
    func thumbnailURL(for mediaId: UUID) -> URL {
        root.appending(path: "\(mediaId.uuidString.lowercased())-thumb.jpg")
    }

    private func normalized(_ ext: String) -> String {
        let cleaned = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return cleaned.isEmpty ? "dat" : cleaned
    }

    // MARK: Writing

    /// Copy a picked or captured file in. Returns the staged location.
    ///
    /// A copy, not a move: the source may be a system-owned temporary the picker still holds,
    /// and moving it out from under PhotoKit is not ours to do.
    @discardableResult
    func stage(contentsOf source: URL, as mediaId: UUID) throws -> URL {
        let destination = originalURL(for: mediaId, ext: source.pathExtension)
        try replaceItem(at: destination) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    @discardableResult
    func stage(data: Data, as mediaId: UUID, ext: String) throws -> URL {
        let destination = originalURL(for: mediaId, ext: ext)
        try replaceItem(at: destination) {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    @discardableResult
    func stageThumbnail(_ data: Data, for mediaId: UUID) throws -> URL {
        let destination = thumbnailURL(for: mediaId)
        try replaceItem(at: destination) {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    /// Re-staging the same id overwrites cleanly. Happens when a retry re-derives a file.
    private func replaceItem(at destination: URL, _ write: () throws -> Void) throws {
        try Self.prepare(root)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try write()
    }

    // MARK: Reading

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func byteCount(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    // MARK: Deleting

    func removeOriginal(for mediaId: UUID, ext: String) {
        try? FileManager.default.removeItem(at: originalURL(for: mediaId, ext: ext))
    }

    func removeThumbnail(for mediaId: UUID) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: mediaId))
    }

    /// Everything belonging to one media row. Used when its entry is deleted.
    func removeAll(for mediaId: UUID) {
        for url in stagedFiles() where url.lastPathComponent.hasPrefix(mediaId.uuidString.lowercased()) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func stagedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// The `media_id` a staged filename belongs to, or nil if it isn't one of ours.
    func mediaId(of url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        let base = name.hasSuffix("-thumb") ? String(name.dropLast("-thumb".count)) : name
        return UUID(uuidString: base)
    }

    func isThumbnail(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix("-thumb")
    }
}
