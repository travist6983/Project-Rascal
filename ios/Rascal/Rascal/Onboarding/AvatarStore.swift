import CoreGraphics
import Foundation
import ImageIO

/// Where a child's avatar lives **on this device** — the cache in front of the server's copy.
///
/// `POST /children/{id}/avatar-upload-url` mints a presigned PUT for a child, so an avatar is no
/// longer device-only: it is written here first and then uploaded, and `children.avatar_key` is
/// what the archive keeps. This file used to say that nothing minted one, which was true when it
/// was written and stopped being true when Lane A built the pair. `AvatarSync` owns the upload and
/// the read-back; this owns the bytes on disk.
///
/// **Local first, and local is still the fast path.** A read serves from here immediately and only
/// falls back to a presigned GET when the file is absent — which after a fresh install is once,
/// and after normal use is never.
///
/// Deliberately **not** `StagingStore`. That directory is excluded from iCloud backup because it
/// holds transient copies of photos the library already has, and re-uploading a video into
/// someone's iCloud quota is waste. An avatar is a crop that exists in no other place on the
/// phone, and a backup is one of the two things standing between it and a lost handset — the
/// server copy is now the other. So the same directory conventions, and the reverse backup flag.
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

    /// **`isExcludedFromBackup = false`, stated rather than inherited.**
    ///
    /// This is the exact inverse of `StagingStore.prepare`, which sets it to `true` two files
    /// away, and the header above has always claimed "the reverse backup flag" — while the code
    /// set nothing at all and merely inherited the default. The behaviour was right by accident.
    /// Saying it out loud is what keeps it right if these two ever grow a shared helper, which is
    /// the only realistic way an avatar directory quietly stops being backed up.
    private static func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = false
        var mutable = url
        try? mutable.setResourceValues(resource)
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
    ///
    /// **`nonisolated` because the two functions below it are.** A `let Int` on a main-actor enum is
    /// main-actor-isolated like everything else on it, so `square(_:focus:)` reading it off the main
    /// thread is a concurrency warning — and a warning is a build failure in this lane.
    nonisolated static let maxPixels = 512

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

    /// The picture, upright, decoded no larger than `maxPixels` on its long edge.
    ///
    /// **The one place orientation is baked, and both callers go through it.** `AvatarFramingScreen`
    /// draws this image and `square(_:focus:)` crops it, so a rectangle drawn on one is a rectangle
    /// on the other — the failure this exists to make unavailable is a crop taken from a portrait
    /// photo that ImageIO handed back sideways, which lands as a picture of somebody's ear and looks
    /// entirely plausible until you compare it to what was framed.
    ///
    /// ImageIO does not upscale, so a picture smaller than `maxPixels` comes back at its own size.
    ///
    /// **`nonisolated`, unlike `square(_:)` above, and the difference is measured rather than
    /// stylistic.** This one is called while a `fullScreenCover` is animating in, and it costs
    /// 30–40ms on a *synthetic* 48-megapixel JPEG in the simulator — two to four frames, and more
    /// on a real photograph, whose entropy is far higher than a two-tone fixture's. A block of that
    /// length during a presentation animation is a visible stutter. Nothing here touches shared
    /// state, so it runs off the main actor and the screen appears immediately with the picture
    /// arriving a frame later, which is what every photo editor does.
    nonisolated static func upright(_ data: Data, maxPixels: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImagePipeline.Failure.unreadable
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
        ] as CFDictionary) else {
            throw ImagePipeline.Failure.notAnImage
        }
        return image
    }

    /// Crop where the parent framed it, rather than at the centre.
    ///
    /// `focus` is a square **in pixels** expressed in coordinates normalised to the upright image —
    /// so `width` and `height` differ whenever the picture is not itself square, and the square is
    /// re-derived in pixels below rather than trusted from the caller. Origin is top-left, which is
    /// both `CGImage.cropping(to:)`'s space and SwiftUI's, so no flip is needed between the screen
    /// that drew it and this.
    ///
    /// **The decode is sized to the crop, not to the picture.** `square(_:)` above thumbnails so the
    /// *short edge* lands on `maxPixels`, which is right when the crop is the whole short edge and
    /// wrong here: a parent who zooms in to a face is asking for a small fraction of the frame, and
    /// taking 512 pixels from a 512-pixel decode of that fraction would hand back something like 90
    /// pixels of child. So the long edge asked for is whatever puts `maxPixels` across the crop —
    /// capped at the original, because asking ImageIO to upscale is meaningless.
    ///
    /// Deliberately **not** folded into `square(_:)` with an optional argument. That path is what
    /// `AvatarStep` ships and it has its own downsample reasoning written into it; a shared body
    /// with two branches would put both sets of arithmetic in one function where the wrong one is
    /// one `if` away.
    /// **`nonisolated` for `upright`'s reason and used differently.** It is called from a button tap
    /// that dismisses the screen behind it, where the app already does this synchronously in two
    /// other places — so it stays on whatever actor the caller is on rather than growing a busy
    /// state for a modal that is closing. The annotation is here so a caller that *does* want it
    /// off the main thread can have it.
    nonisolated static func square(_ data: Data, focus: CGRect) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImagePipeline.Failure.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw ImagePipeline.Failure.notAnImage }

        // **The dimensions above are the *stored* ones, and this only uses the long edge**, which
        // is the one number an orientation tag cannot change: a portrait photo is stored landscape
        // with a tag, so the pair is the same either way round and only which is which moves.
        //
        // The crop is a square in pixels, so as a fraction it is *smaller* of the two normalised
        // sides — that is the one measured against the long edge. `maxPixels / fraction` is then
        // the long edge that puts `maxPixels` across the crop, whichever way the picture is turned.
        // **`min(focus.width, focus.height)` is the crop's fraction of the long edge exactly, and
        // it is orientation-proof — but only because the rectangle is square in pixels.** For a
        // side `s`, `focus.width` is `s / uprightWidth` and `focus.height` is `s / uprightHeight`,
        // so the smaller of the two is `s / max(uprightWidth, uprightHeight)` — and the long edge
        // is the same number whichever way an orientation tag turns the picture, which is what
        // lets this run before the decode that would settle it. **That is the caller's contract**:
        // `AvatarFramingGeometry.focus` guarantees it, and a caller who passes a rectangle that is
        // *not* square in pixels gets a correctly-placed crop at a lower resolution rather than a
        // wrong one, because the squaring below still holds.
        let longEdge = max(width, height)
        let fractionOfLongEdge = max(0.000_1, min(focus.width, focus.height))
        let target = min(
            longEdge,
            max(1, Int((Double(maxPixels) / fractionOfLongEdge).rounded()))
        )

        let decoded = try upright(data, maxPixels: target)
        let drawnWidth = Double(decoded.width)
        let drawnHeight = Double(decoded.height)

        // Re-squared in pixels and pinned inside the image. The screen clamps the drag so this
        // never has anything to do; it is here because a crop rectangle that runs off the picture
        // is the one failure that would produce a half-black avatar rather than an error.
        var side = min(focus.width * drawnWidth, focus.height * drawnHeight).rounded()
        side = max(1, min(side, min(drawnWidth, drawnHeight)))
        let x = min(max(0, (focus.minX * drawnWidth).rounded()), drawnWidth - side)
        let y = min(max(0, (focus.minY * drawnHeight).rounded()), drawnHeight - side)

        guard let cropped = decoded.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
            throw ImagePipeline.Failure.encodingFailed
        }
        return try ImagePipeline.encodeJPEGForPoster(cropped)
    }
}
