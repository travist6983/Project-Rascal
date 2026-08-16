import CoreGraphics
import Foundation
import ImageIO
import MediaAccessibility
import Testing
import UniformTypeIdentifiers

@testable import Rascal

/// The caption probe, against real files rather than a mocked boundary.
///
/// **The point of this suite is that the reader is real.** The probe exists to produce one number
/// that decides whether phase 33's device half gets built, so a test that stubs
/// `MAImageCaptioningCopyCaption` and asserts on the stub would prove nothing about the answer.
/// These write an actual caption into an actual JPEG with `MAImageCaptioningSetCaption` and read
/// it back through the same call the probe uses.
///
/// The camera-roll walk is not covered and cannot be: it needs PhotoKit and a library. That half
/// is checked on a device — see `docs/device-verification-captions.md`.
@Suite("Caption probe")
struct CaptionProbeTests {

    private func makeJPEG() -> Data {
        let context = CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A JPEG on disk, optionally carrying a caption. The caller owns nothing — the file lands in
    /// a unique temp directory that the test process discards.
    private func write(caption: String?) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "photo.jpg")
        try makeJPEG().write(to: url)
        if let caption {
            var error: CFError?
            let ok = MAImageCaptioningSetCaption(url as CFURL, caption as CFString, &error)
            // If the platform will not write the field, every assertion below is meaningless
            // rather than merely failing — so this is the precondition, not a soft check.
            #expect(ok, "MAImageCaptioningSetCaption could not write the XMP field")
        }
        return url
    }

    @Test("A caption written into a file reads back through the same call the probe uses")
    func roundTrip() throws {
        let url = try write(caption: "A boy holding a pumpkin twice his size.")
        #expect(CaptionProbe.caption(at: url) == "A boy holding a pumpkin twice his size.")
    }

    @Test("A photo with no description reads as nil, not as empty string")
    func absent() throws {
        let url = try write(caption: nil)
        #expect(CaptionProbe.caption(at: url) == nil)
    }

    /// A field that exists and says nothing is not a caption. Counting it would inflate the one
    /// number this whole exercise is for, in the direction that argues for building the feature.
    @Test("A whitespace-only description counts as absent")
    func whitespaceIsAbsent() throws {
        let url = try write(caption: "   \n\t  ")
        #expect(CaptionProbe.caption(at: url) == nil)
    }

    @Test("Surrounding whitespace is trimmed rather than reported")
    func trimmed() throws {
        let url = try write(caption: "  He is asleep on the dog.  ")
        #expect(CaptionProbe.caption(at: url) == "He is asleep on the dog.")
    }

    @Test("A file that is not there reads as nil rather than throwing")
    func missingFile() {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/nope.jpg")
        #expect(CaptionProbe.caption(at: url) == nil)
    }

    // MARK: The rate

    /// **Nothing read is unmeasured, not zero**, and the distinction is the whole reason the
    /// property is optional. A scan that opened no files reporting "0%" would answer this
    /// phase's question — *is it worth building* — wrongly, and permanently.
    @Test("A rate over nothing read is nil, not zero")
    func rateIsUnmeasuredWhenNothingWasRead() {
        var report = CaptionProbe.Report()
        #expect(report.hitRate == nil)

        report.scanned = 4
        report.unreadable = 4
        #expect(report.hitRate == nil)
    }

    /// The denominator is what was *read*, not what was walked. Files that could not be opened
    /// are excluded from both halves rather than counted as misses — "we could not look" is not
    /// evidence that there was nothing to see.
    @Test("Unreadable files leave the denominator rather than counting as misses")
    func unreadableFilesAreNotMisses() {
        var report = CaptionProbe.Report()
        report.scanned = 10
        report.unreadable = 6
        report.hits = 2
        #expect(report.hitRate == 0.5)
    }

    @Test("iCloud-only assets never enter the denominator")
    func cloudAssetsAreSeparate() {
        var report = CaptionProbe.Report()
        report.scanned = 4
        report.hits = 1
        report.skippedInCloud = 900
        #expect(report.hitRate == 0.25)
    }

    @Test("Zero hits over real reads is a measured zero")
    func measuredZero() {
        var report = CaptionProbe.Report()
        report.scanned = 200
        report.hits = 0
        #expect(report.hitRate == 0)
    }

    // MARK: Rendering

    @Test("An unmeasured rate says so rather than printing a number")
    func unmeasuredRendersAsWords() {
        #expect(CaptionProbeScreen.rate(nil) == "not measured")
    }

    /// One decimal place, because the interesting distinction is between none and a few in a
    /// hundred, and rounding to an integer collapses exactly that.
    @Test("A small rate survives rounding")
    func smallRateSurvives() {
        #expect(CaptionProbeScreen.rate(0.004) == "0.4%")
        #expect(CaptionProbeScreen.rate(0) == "0.0%")
    }
}
