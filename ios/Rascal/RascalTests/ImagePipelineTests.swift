import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Rascal

/// The image pipeline, with real generated images rather than mocks.
///
/// Orientation is the test that matters. An unrotated JPEG carrying an orientation tag looks
/// correct in Photos and sideways in every non-Apple viewer, and fixing it later means
/// reprocessing the whole archive — so it is asserted on the *pixels*, not on metadata.
@Suite("Image pipeline")
struct ImagePipelineTests {

    /// A wide image with a distinctive corner, so rotation is detectable from pixel data.
    /// 40×20, red except for a single blue pixel at top-left.
    private func makeImage(width: Int = 40, height: Int = 20) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        // Core Graphics origin is bottom-left, so this lands top-left in image terms.
        context.fill(CGRect(x: 0, y: height - 4, width: 4, height: 4))
        return context.makeImage()!
    }

    /// Encode with an explicit EXIF orientation tag and optional capture date.
    private func encode(
        _ image: CGImage,
        type: UTType = .jpeg,
        orientation: UInt32 = 1,
        dateTimeOriginal: String? = nil
    ) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        )!
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let dateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// Where the blue marker sits, as a fraction of width and height.
    ///
    /// Relative rather than absolute on purpose: comparing the marker's position before and
    /// after processing tests that it did not move, without the test having to encode which
    /// corner Core Graphics calls the origin. A convention error cancels out; a real rotation
    /// does not.
    private func markerPosition(_ image: CGImage) -> (x: Double, y: Double)? {
        let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)

        var best: (score: Int, x: Int, y: Int)?
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = (row * image.width + column) * 4
                let score = Int(buffer[offset + 2]) - Int(buffer[offset])  // blue minus red
                if score > 40, score > (best?.score ?? 0) { best = (score, column, row) }
            }
        }
        guard let best else { return nil }
        return (Double(best.x) / Double(image.width), Double(best.y) / Double(image.height))
    }

    private func decode(_ data: Data) -> CGImage {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    // MARK: Format

    @Test("HEIC converts to JPEG")
    func heicBecomesJpeg() throws {
        // HEIC encoding is unavailable on some simulator configurations; the conversion path
        // is identical, so fall back to verifying it from a non-JPEG source rather than
        // skipping the assertion entirely.
        let heic = encode(makeImage(), type: UTType.heic)
        let source = heic.isEmpty ? encode(makeImage(), type: .png) : heic

        let processed = try ImagePipeline.process(data: source)

        #expect(processed.contentType == "image/jpeg")
        #expect(processed.fileExtension == "jpg")
        // JPEG magic number — asserting the bytes, not the label.
        #expect(processed.data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test("original pixel dimensions are preserved — no downscaling")
    func preservesDimensions() throws {
        let processed = try ImagePipeline.process(data: encode(makeImage(width: 64, height: 32)))
        #expect(processed.pixelWidth == 64)
        #expect(processed.pixelHeight == 32)
    }

    // MARK: Orientation — the irreversible one

    @Test("a rotated image comes out upright in the pixels, not as a tag")
    func bakesOrientation() throws {
        // Orientation 6 = rotate 90° clockwise on display. A 40×20 image therefore *displays*
        // as 20×40, and a correct bake swaps the stored dimensions.
        let rotated = encode(makeImage(width: 40, height: 20), orientation: 6)

        let processed = try ImagePipeline.process(data: rotated)

        #expect(processed.pixelWidth == 20, "a baked rotation swaps the stored dimensions")
        #expect(processed.pixelHeight == 40)

        // And no leftover tag — a tag on top of baked rotation rotates it twice in viewers
        // that honour both, which is how a photo ends up upside down.
        let tag = properties(processed.data)[kCGImagePropertyOrientation] as? UInt32
        #expect(tag == nil || tag == 1, "got \(tag ?? 0): a residual tag double-rotates")
    }

    @Test("an already-upright image is left alone")
    func leavesUprightAlone() throws {
        let processed = try ImagePipeline.process(data: encode(makeImage(width: 40, height: 20)))
        #expect(processed.pixelWidth == 40)
        #expect(processed.pixelHeight == 20)

        // The marker is in the same corner it started in.
        let before = try #require(markerPosition(makeImage(width: 40, height: 20)))
        let after = try #require(markerPosition(decode(processed.data)))
        #expect(abs(before.x - after.x) < 0.2, "the marker moved horizontally")
        #expect(abs(before.y - after.y) < 0.2, "the marker moved vertically")
    }

    // MARK: EXIF dates

    @Test("EXIF DateTimeOriginal parses")
    func parsesExifDate() throws {
        let processed = try ImagePipeline.process(
            data: encode(makeImage(), dateTimeOriginal: "2019:07:04 14:30:00")
        )
        let captured = try #require(processed.capturedAt)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: captured)
        #expect(parts.year == 2019)
        #expect(parts.month == 7)
        #expect(parts.day == 4)
        // EXIF carries no zone; it is wall-clock time where the photo was taken.
        #expect(parts.hour == 14)
    }

    @Test("no EXIF date falls back to now rather than guessing")
    func fallsBackCleanly() throws {
        let processed = try ImagePipeline.process(data: encode(makeImage()))
        #expect(processed.capturedAt == nil, "a photo with no date has no date")

        let now = Date()
        #expect(ImagePipeline.occurredAt(for: nil, now: now) == now)
    }

    @Test("a dated photo backdates the entry — the camera-roll backfill story")
    func backdatesFromExif() throws {
        let processed = try ImagePipeline.process(
            data: encode(makeImage(), dateTimeOriginal: "2019:07:04 14:30:00")
        )
        let captured = try #require(processed.capturedAt)
        let occurred = ImagePipeline.occurredAt(for: captured, now: Date())

        #expect(occurred == captured, "a photo from 2019 belongs in 2019, not today")
        #expect(occurred < Date())
    }

    // MARK: Thumbnails

    @Test("a thumbnail is produced, readable, and bounded")
    func makesThumbnail() throws {
        let processed = try ImagePipeline.process(data: encode(makeImage(width: 2000, height: 1000)))

        #expect(!processed.thumbnail.isEmpty)
        #expect(processed.thumbnail.prefix(2) == Data([0xFF, 0xD8]))

        let thumb = decode(processed.thumbnail)
        #expect(max(thumb.width, thumb.height) <= ImagePipeline.thumbnailMaxPixels)
        #expect(processed.thumbnail.count < processed.data.count, "a thumbnail should be smaller")
    }

    @Test("the thumbnail is oriented the same way as the original")
    func thumbnailAgreesWithOriginal() throws {
        let processed = try ImagePipeline.process(
            data: encode(makeImage(width: 40, height: 20), orientation: 6)
        )
        let thumb = decode(processed.thumbnail)
        // Both portrait after the bake. A thumbnail that disagrees with its original is the
        // bug where a timeline row is sideways and the detail view is not.
        #expect(thumb.height > thumb.width)
        #expect(processed.pixelHeight > processed.pixelWidth)
    }

    // MARK: Failure

    @Test("unreadable input fails loudly rather than producing an empty file")
    func rejectsGarbage() {
        #expect(throws: ImagePipeline.Failure.self) {
            try ImagePipeline.process(data: Data("not an image".utf8))
        }
    }

    @Test("a missing file is unreadable, not a crash")
    func rejectsMissingFile() {
        let missing = URL(filePath: NSTemporaryDirectory()).appending(path: "nope-\(UUID()).jpg")
        #expect(throws: ImagePipeline.Failure.unreadable) {
            try ImagePipeline.process(fileAt: missing)
        }
    }
}
