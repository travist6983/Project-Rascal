import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// Turns a picked or captured image into what the archive should hold.
///
/// Three decisions here are effectively permanent, because undoing them later means
/// reprocessing every photo already stored:
///
/// 1. **JPEG, not HEIC.** The archive should open in 2040 in something that isn't Apple.
/// 2. **Orientation baked into the pixels.** An unrotated JPEG carrying an EXIF orientation
///    tag displays upright in Photos and sideways nearly everywhere else. Storing it rotated
///    is the only version that is right in both.
/// 3. **No downscaling.** Transcode policy is an open decision and not this layer's to make.
enum ImagePipeline {

    struct Processed {
        /// JPEG bytes, upright, full resolution.
        let data: Data
        /// EXIF `DateTimeOriginal` where the source had one.
        let capturedAt: Date?
        /// Square-ish JPEG for the timeline. Disposable: losing it degrades to a refetch
        /// through `presign_get`, never to a broken view.
        let thumbnail: Data
        let pixelWidth: Int
        let pixelHeight: Int

        var contentType: String { "image/jpeg" }
        var fileExtension: String { "jpg" }
    }

    enum Failure: Error, Equatable {
        case unreadable
        case notAnImage
        case encodingFailed
    }

    /// Quality 0.85 — visually indistinguishable from the original at normal viewing sizes,
    /// roughly a third of the bytes. The tradeoff a photo archive wants.
    static let jpegQuality: CGFloat = 0.85
    /// Longest edge of the cached thumbnail. Comfortably covers a 3x timeline row.
    static let thumbnailMaxPixels = 400

    static func process(fileAt url: URL) throws -> Processed {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable
        }
        return try process(source: source)
    }

    static func process(data: Data) throws -> Processed {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.unreadable
        }
        return try process(source: source)
    }

    private static func process(source: CGImageSource) throws -> Processed {
        guard CGImageSourceGetCount(source) > 0 else { throw Failure.notAnImage }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let capturedAt = exifDate(from: properties)

        // The orientation tag is deliberately *not* read here. `kCGImageSourceCreateThumbnail-
        // WithTransform` applies it to the pixels for us, and a second copy of that value lying
        // around invites someone to "helpfully" apply it again — which double-rotates.
        //
        // `kCGImageSourceCreateThumbnailWithTransform` is what applies the orientation to the
        // pixels rather than leaving it as a tag. Asking for a "thumbnail" the size of the
        // largest edge is the documented way to get a full-size, transformed image without
        // hand-rolling a CGContext rotation.
        let maxEdge = max(
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
        guard maxEdge > 0 else { throw Failure.notAnImage }

        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ] as CFDictionary) else {
            throw Failure.notAnImage
        }

        guard let jpeg = encodeJPEG(upright, quality: jpegQuality) else {
            throw Failure.encodingFailed
        }

        // Derived from the already-upright image, so the thumbnail cannot disagree with the
        // original about which way is up.
        let thumbnail = try makeThumbnail(from: source)

        return Processed(
            data: jpeg,
            capturedAt: capturedAt,
            thumbnail: thumbnail,
            pixelWidth: upright.width,
            pixelHeight: upright.height
        )
    }

    /// A standalone thumbnail, also orientation-corrected. Used by the composer preview and
    /// cached for Phase 3's timeline, where `thumb_key` is null server-side.
    static func makeThumbnail(from source: CGImageSource) throws -> Data {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
        ] as CFDictionary) else {
            throw Failure.notAnImage
        }
        guard let data = encodeJPEG(image, quality: 0.8) else { throw Failure.encodingFailed }
        return data
    }

    static func makeThumbnail(fileAt url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable
        }
        return try makeThumbnail(from: source)
    }

    // MARK: Internals

    /// Redraw without an alpha channel before encoding.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` hands back `premultipliedLast` even for a fully
    /// opaque photo. JPEG cannot store alpha at all, so encoding it that way buys nothing and
    /// ImageIO says so on device:
    ///
    ///     'Rascal' is trying to save an opaque image (4284x5712) with 'AlphaPremulLast'.
    ///     This would ... double (!!!) the required memory when decoding
    ///
    /// Doubling decode memory on a 24-megapixel photo is not academic — a multi-photo import
    /// is the case most likely to be killed for memory, and it is the one this app is for.
    private static func withoutAlpha(_ image: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let image = withoutAlpha(image)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        // No orientation tag is written: the pixels are already upright, and a tag on top of
        // baked rotation would rotate it twice in viewers that honour both.
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// EXIF `DateTimeOriginal`, falling back to `DateTimeDigitized`, then TIFF `DateTime`.
    ///
    /// Returns nil rather than guessing. A photo with no date is a photo with no date, and
    /// inventing one puts a wrong day in a permanent archive.
    static func exifDate(from properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let candidates = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String,
        ]
        for raw in candidates.compactMap({ $0 }) {
            if let date = exifFormatter.date(from: raw) { return date }
        }
        return nil
    }

    static func exifDate(fileAt url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return exifDate(from: properties)
    }

    /// EXIF timestamps are `yyyy:MM:dd HH:mm:ss` with **no timezone** — they are wall-clock
    /// time where the photo was taken. Interpreting them in the device's current zone is the
    /// closest honest reading; treating them as UTC would shift every backfilled photo by
    /// hours and land some on the wrong day.
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}

extension ImagePipeline {
    /// What the composer sets `occurred_at` to for a picked photo.
    ///
    /// The EXIF date when there is one — this is the camera-roll backfill story, and a photo
    /// from 2019 belongs in 2019, not today. `now` only when the file genuinely carries no
    /// date, because a guess in a permanent archive is worse than an honest default.
    static func occurredAt(for capturedAt: Date?, now: Date = Date()) -> Date {
        capturedAt ?? now
    }
}
