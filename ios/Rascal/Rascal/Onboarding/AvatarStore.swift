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

    /// A path nothing is ever written to. This store keeps its bytes in memory, and handing back
    /// a plausible-looking real path would invite a caller to read from it and find nothing.
    func url(for childId: UUID) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "in-memory-avatar-store")
            .appending(path: "\(childId.uuidString.lowercased()).jpg")
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

    /// Centre-crop to a square at avatar size.
    ///
    /// Centre rather than face-aware: Vision would be a better crop and it would also be a new
    /// dependency on a framework this lane has never loaded, for a picture the parent can retake.
    ///
    /// **Downsampled before anything else touches it, and that is the whole design.** The obvious
    /// version — run `ImagePipeline.process`, crop the result, then shrink it — decodes a
    /// 24-megapixel photo at full size, JPEG-encodes it at full size, builds a thumbnail nobody
    /// wants, decodes again, and encodes twice more, to produce 512 pixels. `ImagePipeline`'s own
    /// comments are about exactly this cost ("doubling decode memory on a 24-megapixel photo is
    /// not academic"), and this runs while a parent is waiting on the last screen of setup.
    ///
    /// So: one `CGImageSourceCreateThumbnailAtIndex` sized so the *short* edge lands on
    /// `maxPixels`, which never decodes the full image, then one crop, then one encode. HEIC→JPEG
    /// and the orientation bake are the same ImageIO mechanisms `ImagePipeline` uses, and the
    /// encode is `ImagePipeline`'s own, so the alpha-stripping rule is not re-derived here.
    static func square(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImagePipeline.Failure.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw ImagePipeline.Failure.notAnImage }

        // `ThumbnailMaxPixelSize` constrains the *long* edge, and the crop below consumes the
        // short one — so ask for a long edge that leaves `maxPixels` across the short. Capped at
        // the original, because ImageIO will not upscale and asking it to is meaningless.
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        let target = min(
            longEdge,
            Int((Double(maxPixels) * Double(longEdge) / Double(shortEdge)).rounded())
        )

        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Orientation baked into the pixels, never left as a tag — the same call and the
            // same reason as `ImagePipeline`: a tag on top of baked rotation rotates it twice.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ] as CFDictionary) else {
            throw ImagePipeline.Failure.notAnImage
        }

        let edge = min(upright.width, upright.height)
        guard edge > 0, let cropped = upright.cropping(to: CGRect(
            x: (upright.width - edge) / 2,
            y: (upright.height - edge) / 2,
            width: edge,
            height: edge
        )) else {
            throw ImagePipeline.Failure.encodingFailed
        }

        return try ImagePipeline.encodeJPEGForPoster(cropped)
    }
}
