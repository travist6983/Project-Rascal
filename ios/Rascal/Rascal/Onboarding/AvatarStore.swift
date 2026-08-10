import CoreGraphics
import Foundation
import ImageIO

/// Where a child's avatar lives.
///
/// **On this device and nowhere else, for now.** The API has an `children.avatar_key` column and
/// `PATCH /children/{id}` accepts a key, but nothing mints one: `POST /media/upload-url` requires
/// an `entry_id` and creates a media row against an entry, so there is no route that presigns an
/// upload for a child. Sending avatar bytes through the entry-scoped route would put a picture of
/// a child into the archive as an entry's artifact, which is a worse outcome than not uploading
/// it. See `docs/blocked.md` for the endpoint this needs.
///
/// Deliberately **not** `StagingStore`. That directory is excluded from iCloud backup because it
/// holds transient copies of photos the library already has, and re-uploading a video into
/// someone's iCloud quota is waste. This is the opposite case: an avatar is a crop that exists in
/// no other place, and until there is somewhere to upload it, a backup is the only thing standing
/// between it and a lost phone. So the same directory conventions, and the reverse backup flag.
nonisolated protocol AvatarStoring: Sendable {
    func save(_ jpeg: Data, for childId: UUID)
    func load(for childId: UUID) -> Data?
    func remove(for childId: UUID)
    func url(for childId: UUID) -> URL
}

nonisolated struct LocalAvatarStore: AvatarStoring {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot()
        try? Self.prepare(self.root)
    }

    private static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "avatars", directoryHint: .isDirectory)
    }

    private static func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func url(for childId: UUID) -> URL {
        root.appending(path: "\(childId.uuidString.lowercased()).jpg")
    }

    func save(_ jpeg: Data, for childId: UUID) {
        try? Self.prepare(root)
        try? jpeg.write(to: url(for: childId), options: .atomic)
    }

    func load(for childId: UUID) -> Data? {
        try? Data(contentsOf: url(for: childId))
    }

    func remove(for childId: UUID) {
        try? FileManager.default.removeItem(at: url(for: childId))
    }
}

nonisolated final class InMemoryAvatarStore: AvatarStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: Data] = [:]

    func save(_ jpeg: Data, for childId: UUID) {
        lock.lock(); defer { lock.unlock() }
        stored[childId] = jpeg
    }

    func load(for childId: UUID) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored[childId]
    }

    func remove(for childId: UUID) {
        lock.lock(); defer { lock.unlock() }
        stored[childId] = nil
    }

    func url(for childId: UUID) -> URL {
        URL(fileURLWithPath: "/dev/null/\(childId.uuidString.lowercased()).jpg")
    }
}

/// Square-crop an image and hand back JPEG bytes.
///
/// The conversion itself is `ImagePipeline`'s and is not reimplemented here: HEIC→JPEG,
/// orientation baked into the pixels, alpha stripped before encoding. This adds the one thing an
/// avatar needs that an archive photo must never have — a crop.
///
/// Main-actor isolated, like `ImagePipeline.process(data:)` itself and like the composer's own
/// picked-photo path. An avatar is one image chosen once during setup, so there is nothing here
/// worth the seam that the thumbnail path needed.
enum AvatarCrop {
    /// Longest edge of the stored avatar. A 42pt circle at 3x is 126px; 512 covers every place
    /// an avatar could grow into without storing a full-resolution portrait per child.
    static let maxPixels = 512

    /// Centre-crop to a square, then run the existing pipeline over it.
    ///
    /// Centre rather than face-aware: Vision would be a better crop and it would also be a new
    /// dependency on a framework this lane has never loaded, for a picture the parent can retake.
    static func square(_ data: Data) throws -> Data {
        let processed = try ImagePipeline.process(data: data)
        guard let source = CGImageSourceCreateWithData(processed.data as CFData, nil),
              let upright = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImagePipeline.Failure.notAnImage }

        let edge = min(upright.width, upright.height)
        let rect = CGRect(
            x: (upright.width - edge) / 2,
            y: (upright.height - edge) / 2,
            width: edge,
            height: edge
        )
        guard let cropped = upright.cropping(to: rect) else {
            throw ImagePipeline.Failure.encodingFailed
        }

        // Back through ImageIO to downsample and re-encode, so the stored file is a modest
        // square rather than a full-resolution photo with most of it thrown away.
        let squareJPEG = try ImagePipeline.encodeJPEGForPoster(cropped)
        guard let squareSource = CGImageSourceCreateWithData(squareJPEG as CFData, nil),
              let reduced = CGImageSourceCreateThumbnailAtIndex(squareSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return squareJPEG }

        return try ImagePipeline.encodeJPEGForPoster(reduced)
    }
}
