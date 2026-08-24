import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Rascal

// MARK: - Phase 118: where the circle falls

/// **The arithmetic, not the screen.** A crop that is off by the height of a header is a photograph
/// of somebody's chin, and it looks entirely plausible on every screenshot until you hold it beside
/// what the parent actually framed. `AvatarFramingGeometry` exists as a value type so this is
/// checkable without rendering anything.
@Suite("Avatar framing — the crop rectangle")
struct AvatarFramingGeometryTests {

    private let square = AvatarFramingGeometry(imageSize: CGSize(width: 1_000, height: 1_000), viewport: 300)
    /// 2:1, which is the case the whole framing step exists for: a child in the left third of a
    /// landscape photo comes out as grass under a centre crop.
    private let landscape = AvatarFramingGeometry(imageSize: CGSize(width: 2_000, height: 1_000), viewport: 300)

    @Test("at rest the crop is the centred circle, on a square photo")
    func restingCropIsCentredOnASquare() {
        let focus = square.focus(offset: .zero, scale: 1)
        #expect(abs(focus.width - AvatarFramingGeometry.circleRatio) < 0.000_1)
        #expect(abs(focus.height - AvatarFramingGeometry.circleRatio) < 0.000_1)
        #expect(abs(focus.minX - (1 - AvatarFramingGeometry.circleRatio) / 2) < 0.000_1)
        #expect(abs(focus.minY - (1 - AvatarFramingGeometry.circleRatio) / 2) < 0.000_1)
    }

    /// The crop is a square **in pixels**, so on a 2:1 photo it is half as wide a fraction as it is
    /// tall. Normalised coordinates make that asymmetry easy to get backwards, and getting it
    /// backwards produces a stretched avatar rather than an error.
    @Test("the crop is square in pixels, not in normalised coordinates")
    func cropIsSquareInPixels() {
        for scale in [1.0, 1.7, 3.0, 6.0] as [CGFloat] {
            let focus = landscape.focus(offset: .zero, scale: scale)
            let widthPixels = focus.width * landscape.imageSize.width
            let heightPixels = focus.height * landscape.imageSize.height
            #expect(abs(widthPixels - heightPixels) < 0.01, "at \(scale)×")
        }
    }

    @Test("at rest the crop is centred on a landscape photo too")
    func restingCropIsCentredOnALandscape() {
        let focus = landscape.focus(offset: .zero, scale: 1)
        #expect(abs(focus.midX - 0.5) < 0.000_1)
        #expect(abs(focus.midY - 0.5) < 0.000_1)
    }

    /// **Dragging past the edge stops at the edge.** There is no framing in which the saved square
    /// is part photograph and part nothing — which is what a rectangle running off the picture
    /// would encode, and it would render as a half-black avatar rather than as a failure.
    @Test("the crop never leaves the picture, however far it is dragged")
    func cropStaysInsideThePicture() {
        for geometry in [square, landscape] {
            for scale in [1.0, 2.4, 6.0] as [CGFloat] {
                for offset in [
                    CGSize(width: 5_000, height: 0), CGSize(width: -5_000, height: 0),
                    CGSize(width: 0, height: 5_000), CGSize(width: 0, height: -5_000),
                    CGSize(width: 5_000, height: -5_000),
                ] {
                    let focus = geometry.focus(offset: offset, scale: scale)
                    #expect(focus.minX >= -0.000_1)
                    #expect(focus.minY >= -0.000_1)
                    #expect(focus.maxX <= 1.000_1)
                    #expect(focus.maxY <= 1.000_1)
                }
            }
        }
    }

    /// Dragged all the way right, the crop's left edge is the picture's left edge — not somewhere
    /// near it. The clamp is exact or it is a rounding error waiting to become a black seam.
    @Test("dragged to the stop, the crop sits exactly on the edge")
    func draggingToTheStopLandsOnTheEdge() {
        let focus = landscape.focus(offset: CGSize(width: 9_999, height: 0), scale: 1)
        #expect(abs(focus.minX) < 0.000_1)

        let other = landscape.focus(offset: CGSize(width: -9_999, height: 0), scale: 1)
        #expect(abs(other.maxX - 1) < 0.000_1)
    }

    /// Zooming in takes less of the picture. The direction is the kind of thing that is inverted in
    /// exactly one of the two places it is written.
    @Test("zooming in shrinks the crop")
    func zoomingInShrinksTheCrop() {
        let resting = square.focus(offset: .zero, scale: 1)
        let zoomed = square.focus(offset: .zero, scale: 3)
        #expect(zoomed.width < resting.width)
        #expect(abs(zoomed.width - resting.width / 3) < 0.000_1)
    }

    @Test("scale is clamped to actual size and 6×")
    func scaleIsClamped() {
        #expect(AvatarFramingGeometry.clampedScale(0.01) == AvatarFramingGeometry.minScale)
        #expect(AvatarFramingGeometry.clampedScale(1_000) == AvatarFramingGeometry.maxScale)
        #expect(AvatarFramingGeometry.clampedScale(2.5) == 2.5)
    }

    /// **At `minScale` the picture already covers the circle**, on any aspect ratio — which is the
    /// property that lets the screen get away with one clamp instead of a separate coverage rule.
    @Test("the picture covers the circle at every legal scale")
    func thePictureAlwaysCoversTheCircle() {
        for size in [CGSize(width: 4_000, height: 300), CGSize(width: 300, height: 4_000), CGSize(width: 8, height: 8)] {
            let geometry = AvatarFramingGeometry(imageSize: size, viewport: 300)
            let drawn = geometry.drawnSize(scale: AvatarFramingGeometry.minScale)
            #expect(drawn.width >= geometry.circle - 0.000_1, "\(size)")
            #expect(drawn.height >= geometry.circle - 0.000_1, "\(size)")
        }
    }

    /// A zero-sized image is reachable for one frame — `AvatarFramingScreen` builds the geometry
    /// before `prepare()` has decoded anything. It must not divide by zero on the way.
    @Test("an undecoded picture does not produce a nonsense rectangle")
    func undecodedPictureIsSafe() {
        let empty = AvatarFramingGeometry(imageSize: .zero, viewport: 300)
        let focus = empty.focus(offset: CGSize(width: 40, height: 40), scale: 2)
        #expect(focus.width.isFinite)
        #expect(focus.height.isFinite)
    }
}

// MARK: - The crop itself

/// **Pixels, not reasoning.** `AvatarFramingGeometryTests` proves the rectangle is right; this
/// proves the rectangle is the one that gets cropped. The two halves failed independently in
/// development — a correct rectangle applied to a differently-oriented decode is the failure this
/// pair is here to catch.
@Suite("Avatar framing — the crop that comes out")
@MainActor
struct AvatarFocusCropTests {

    /// Left half red, right half blue, at whatever size is asked for — **in pixels**.
    ///
    /// `scale = 1` is load-bearing rather than tidy. `UIGraphicsImageRenderer` defaults to the
    /// device's scale, so a renderer asked for 1200 x 600 on a 3x simulator hands back a
    /// 3600 x 1800 JPEG — and a test that then asserts something about "1200 pixels" is asserting
    /// about a number that is not in the file. That is how the ceiling below first read as broken
    /// when it was the fixture that was three times the size it claimed.
    private func twoTone(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.blue.setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
        return image.jpegData(compressionQuality: 1)!
    }

    /// Fraction of pixels that are unambiguously the named channel. Nothing in the palette is close
    /// to either of these, and JPEG ringing at the seam is why this is a fraction and not a count.
    private func share(_ data: Data, red wantsRed: Bool) throws -> Double {
        let image = try #require(UIImage(data: data)?.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hits = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if wantsRed ? (r > 140 && g < 110 && b < 110) : (b > 140 && r < 110 && g < 110) { hits += 1 }
        }
        return Double(hits) / Double(width * height)
    }

    /// The whole point of the step: the parent frames the right-hand third and gets the right-hand
    /// third. Under `square(_:)` the same photo centre-crops across the seam.
    @Test("the crop comes from where it was framed, not from the centre")
    func theCropIsWhereItWasFramed() throws {
        let data = twoTone(width: 400, height: 200)

        let right = try AvatarCrop.square(data, focus: CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8))
        #expect(try share(right, red: false) > 0.95)

        let left = try AvatarCrop.square(data, focus: CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8))
        #expect(try share(left, red: true) > 0.95)

        // And the shipped centre crop still straddles the seam, which is the behaviour the framing
        // step exists to give the parent a way out of rather than a bug to fix underneath them.
        let centred = try AvatarCrop.square(data)
        #expect(try share(centred, red: true) > 0.2)
        #expect(try share(centred, red: false) > 0.2)
    }

    @Test("what comes out is square")
    func theCropIsSquare() throws {
        let data = twoTone(width: 400, height: 200)
        let cropped = try AvatarCrop.square(data, focus: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.6))
        let image = try #require(UIImage(data: cropped)?.cgImage)
        #expect(image.width == image.height)
    }

    /// **The decode is sized to the crop, not to the picture**, and this is the number that says so.
    /// `square(_:)` thumbnails so the *short edge* lands on 512, which for a crop covering a quarter
    /// of the frame would hand back about 128 pixels of child. Sizing the decode to the crop keeps
    /// it near 512.
    @Test("a tight crop is not a tiny picture")
    func aTightCropKeepsItsResolution() throws {
        let data = twoTone(width: 2_000, height: 2_000)
        let cropped = try AvatarCrop.square(data, focus: CGRect(x: 0.4, y: 0.4, width: 0.25, height: 0.25))
        let image = try #require(UIImage(data: cropped)?.cgImage)
        #expect(image.width > 400, "a quarter-frame crop came back at \(image.width)px")
    }

    /// A crop can be asked for that no longer fits after rounding, and the answer is a picture at
    /// the edge rather than a throw — the parent framed something legal and a rounding error is not
    /// their problem.
    @Test("a rectangle running off the edge is pulled back onto the picture")
    func anOverhangingRectangleIsPulledBack() throws {
        let data = twoTone(width: 400, height: 200)
        let cropped = try AvatarCrop.square(data, focus: CGRect(x: 0.9, y: 0.9, width: 0.4, height: 0.8))
        let image = try #require(UIImage(data: cropped)?.cgImage)
        #expect(image.width == image.height)
        #expect(image.width > 0)
    }

    @Test("something that is not an image still throws rather than producing bytes")
    func rubbishStillThrows() {
        #expect(throws: (any Error).self) {
            try AvatarCrop.square(Data("not a picture".utf8), focus: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// `upright` is the shared decode both the screen and the crop go through, so a picture that
    /// draws must be a picture that crops.
    @Test("upright decodes to no larger than it was asked for")
    func uprightRespectsItsCeiling() throws {
        let data = twoTone(width: 1_200, height: 600)
        let image = try AvatarCrop.upright(data, maxPixels: 300)
        #expect(max(image.width, image.height) <= 300)
        // ImageIO does not upscale, and asking it to is meaningless.
        let big = try AvatarCrop.upright(data, maxPixels: 5_000)
        #expect(max(big.width, big.height) <= 1_200)
    }
}

// MARK: - What you see is what you get

/// **The one assertion that ties the two halves together.** `AvatarFramingGeometryTests` proves the
/// rectangle is right and `AvatarFocusCropTests` proves the rectangle is what gets cropped — but
/// both would still pass if the *picture on screen* were drawn at a different scale from the one the
/// geometry models. A parent would frame a face and get an ear, and every test in this file would be
/// green.
///
/// So: render the picture at a known framing, read the pixel under the middle of the circle, and
/// compare it against the middle pixel of what `AvatarCrop` hands back for the same framing.
@Suite("Avatar framing — the screen agrees with the crop")
@MainActor
struct AvatarFramingPictureTests {

    private func twoTone(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.blue.setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }.jpegData(compressionQuality: 1)!
    }

    private func centrePixel(_ image: CGImage) throws -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draw the image scaled so that its centre pixel lands in the single pixel of this context.
        let side = CGFloat(min(image.width, image.height))
        let cropped = try #require(image.cropping(to: CGRect(
            x: (CGFloat(image.width) - side / 8) / 2,
            y: (CGFloat(image.height) - side / 8) / 2,
            width: side / 8,
            height: side / 8
        )))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func isBlue(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.b > 140 && pixel.r < 110 && pixel.g < 110
    }

    private func isRed(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.r > 140 && pixel.g < 110 && pixel.b < 110
    }

    /// Dragged hard left, the circle sits over the right-hand half of a two-tone photo. What is
    /// drawn there and what is cropped from there must be the same colour — on a picture where
    /// being off by any amount at all lands on the other one.
    @Test("the pixel under the circle is the pixel that gets saved")
    func whatIsDrawnIsWhatIsCropped() throws {
        let data = twoTone(width: 800, height: 400)
        let image = try #require(UIImage(data: data))
        let geometry = AvatarFramingGeometry(
            imageSize: CGSize(width: image.cgImage!.width, height: image.cgImage!.height),
            viewport: 300
        )

        for (offset, wantsBlue) in [
            (CGSize(width: -9_999, height: 0), true),
            (CGSize(width: 9_999, height: 0), false),
        ] {
            let clamped = geometry.clamped(offset: offset, scale: 1)
            let renderer = ImageRenderer(content: AvatarFramingPicture(
                image: image, geometry: geometry, offset: clamped, scale: 1
            ))
            renderer.scale = 1
            let drawn = try #require(renderer.uiImage?.cgImage)
            let onScreen = try centrePixel(drawn)

            let saved = try #require(UIImage(
                data: try AvatarCrop.square(data, focus: geometry.focus(offset: offset, scale: 1))
            )?.cgImage)
            let inTheFile = try centrePixel(saved)

            #expect(isBlue(onScreen) == wantsBlue, "on screen at \(offset): \(onScreen)")
            #expect(isBlue(inTheFile) == wantsBlue, "in the file at \(offset): \(inTheFile)")
            #expect(isBlue(onScreen) == isBlue(inTheFile))
            #expect(isRed(onScreen) == isRed(inTheFile))
        }
    }
}
