import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Rascal

/// The staging contract between the share extension and the app.
///
/// The extension is its own module and the test host is the app, so nothing in `RascalShare/` is
/// reachable from here. Everything that a share sheet's correctness actually rests on therefore
/// lives in `Rascal/Share/` — the record, the container, the date rule and the copy — and this
/// suite is why it was put there rather than left in the views.
@MainActor
@Suite("Share inbox")
struct ShareInboxTests {

    /// Anchors `Bundle(for:)`. Swift Testing suites are structs, and a bundle lookup needs a
    /// class in the test target.
    private final class BundleAnchor {}

    /// An inbox pointed at a throwaway directory. The real one needs an App Group entitlement,
    /// which the test runner does not have and must not be made to depend on — the same
    /// arrangement `WidgetSnapshotWriteTests` uses.
    private func temporaryInbox() -> ShareInbox {
        ShareInbox(directory: URL.temporaryDirectory.appending(path: "share-\(UUID().uuidString)"))
    }

    // MARK: Fixtures

    /// A tiny real image, optionally carrying an EXIF capture date. Generated rather than
    /// checked in, the way `ImagePipelineTests` does it.
    private func imageData(dateTimeOriginal: String? = nil) -> Data {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.35, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        )!
        var properties: [CFString: Any] = [:]
        if let dateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A file on disk somewhere the inbox is not, standing in for what an `NSItemProvider` hands
    /// over.
    private func sourceFile(_ data: Data, ext: String = "jpg") throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "src-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    private func record(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        occurredAt: Date = Date(),
        source: PendingShare.DateSource = .shareTime,
        note: String? = nil,
        media: [PendingShare.Item] = []
    ) -> PendingShare {
        PendingShare(
            id: id, createdAt: createdAt, occurredAt: occurredAt,
            occurredAtSource: source, note: note, media: media
        )
    }

    private func item(
        id: UUID = UUID(),
        kind: ShareMediaKind = .photo,
        capturedAt: Date? = nil
    ) -> PendingShare.Item {
        PendingShare.Item(
            id: id,
            filename: ShareInbox.filename(for: id, ext: kind == .video ? "mov" : "jpg"),
            kind: kind,
            byteCount: 1234,
            capturedAt: capturedAt
        )
    }

    // MARK: The record

    @Test("a pending record round-trips through encode and decode")
    func roundTrips() throws {
        let inbox = temporaryInbox()
        let captured = Date(timeIntervalSince1970: 1_562_250_600)
        let written = record(
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            occurredAt: captured,
            source: .captureMetadata,
            note: "he ate the whole thing",
            media: [item(kind: .photo, capturedAt: captured), item(kind: .video, capturedAt: nil)]
        )

        try inbox.write(written)

        let read = try #require(inbox.pending().first)
        #expect(read == written, "the record that came back is not the one that went in")
        #expect(read.media.count == 2)
        #expect(read.media[0].kind == .photo)
        #expect(read.media[1].kind == .video)
        #expect(read.occurredAtSource == .captureMetadata)
        #expect(read.note == "he ate the whole thing")
    }

    /// **Rejected, not misread.** The version is probed before the record is decoded, so a future
    /// version that removes or retypes a field is refused knowingly rather than failing to decode
    /// and being indistinguishable from a corrupt file.
    @Test("a version this build does not speak is rejected rather than misread")
    func rejectsForeignVersion() throws {
        let inbox = temporaryInbox()
        let future = PendingShare(
            version: PendingShare.currentVersion + 1,
            id: UUID(), createdAt: Date(), occurredAt: Date(),
            occurredAtSource: .shareTime, note: "from a newer build", media: [item()]
        )
        try inbox.write(future)

        #expect(inbox.pending().isEmpty, "a foreign version was drained")
        #expect(inbox.unreadableCount() == 1, "it must still be counted, not forgotten")

        // And it is **left on disk**. The build that can read it is the next launch away, and a
        // record deleted for being from the future is a photo deleted for being from the future.
        let url = try #require(inbox.recordURL(for: future.id))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a shape this build cannot decode at all is refused, not guessed at")
    func rejectsGarbage() throws {
        let inbox = temporaryInbox()
        try inbox.write(record())
        let directory = try #require(inbox.recordsDirectory)

        try Data("{ not json".utf8).write(to: directory.appending(path: "\(UUID().uuidString).json"))
        // Right version, wrong everything else.
        try Data(#"{"version":1,"id":"nope"}"#.utf8)
            .write(to: directory.appending(path: "\(UUID().uuidString).json"))

        #expect(inbox.pending().count == 1, "a broken record reached the drain")
        #expect(inbox.unreadableCount() == 2)
    }

    @Test("records come back oldest share first")
    func ordersByCreation() throws {
        let inbox = temporaryInbox()
        let old = record(createdAt: Date(timeIntervalSince1970: 1_000_000))
        let new = record(createdAt: Date(timeIntervalSince1970: 2_000_000))
        try inbox.write(new)
        try inbox.write(old)

        #expect(inbox.pending().map(\.id) == [old.id, new.id])
    }

    // MARK: occurred_at — the detail that matters most

    @Test("occurred_at resolves from capture metadata when there is any")
    func resolvesFromMetadata() {
        let captured = Date(timeIntervalSince1970: 1_562_250_600)
        let now = Date()
        let resolved = PendingShare.resolveOccurredAt(captures: [captured], now: now)

        #expect(resolved.date == captured)
        #expect(resolved.source == .captureMetadata)
        #expect(resolved.date != now)
    }

    /// **The fallback is flagged, which is the whole point of recording a source.** A date that
    /// stood in has to be distinguishable from one that was read, or the extension cannot say so
    /// and the parent cannot know.
    @Test("with no capture date anywhere it falls back to now, and says that it did")
    func fallsBackAndSaysSo() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let resolved = PendingShare.resolveOccurredAt(captures: [nil, nil], now: now)

        #expect(resolved.date == now)
        #expect(resolved.source == .shareTime)
    }

    /// The earliest, not the latest and not now. Three photos from one afternoon belong on that
    /// afternoon, and one of them having no date must not drag the entry forward to today.
    @Test("the earliest capture date wins, and an undated file does not drag it to today")
    func picksEarliest() {
        let afternoon = Date(timeIntervalSince1970: 1_562_250_600)
        let evening = afternoon.addingTimeInterval(4 * 3600)
        let now = Date()

        let resolved = PendingShare.resolveOccurredAt(captures: [evening, nil, afternoon], now: now)
        #expect(resolved.date == afternoon)
        #expect(resolved.source == .captureMetadata)
    }

    /// **One rule, not two that agree today.** The composer's picked-photo date and the share
    /// sheet's are now the same function; this is what stops them drifting apart later.
    @Test("the composer and the share sheet resolve the same date from the same dates")
    func composerAndShareAgree() {
        let afternoon = Date(timeIntervalSince1970: 1_562_250_600)
        let now = Date(timeIntervalSince1970: 1_786_000_000)

        let drafts = [
            MediaDraft(
                id: UUID(), stagedURL: URL(filePath: "/dev/null"), fileExtension: "jpg",
                byteCount: 1, contentType: "image/jpeg", capturedAt: afternoon, thumbnail: Data()
            ),
            MediaDraft(
                id: UUID(), stagedURL: URL(filePath: "/dev/null"), fileExtension: "jpg",
                byteCount: 1, contentType: "image/jpeg", capturedAt: nil, thumbnail: Data()
            ),
        ]

        #expect(
            MediaDraftBuilder.suggestedOccurredAt(for: drafts, now: now)
                == PendingShare.resolveOccurredAt(captures: drafts.map(\.capturedAt), now: now).date
        )
        #expect(MediaDraftBuilder.suggestedOccurredAt(for: [], now: now) == now)
    }

    /// **A photo from another year is filed in that year, not this week.**
    ///
    /// The failure this guards against is silent: an entry filed under today looks completely
    /// normal, is on the wrong day, and stays there. Read through the real EXIF path rather than
    /// a hand-made `Date`, so a change to how EXIF is parsed fails here.
    @Test("an EXIF date from another year beats today, through the real read")
    func exifBeatsTodayEndToEnd() throws {
        let inbox = temporaryInbox()
        let mediaId = UUID()
        let source = try sourceFile(imageData(dateTimeOriginal: "2019:07:04 14:30:00"))
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try inbox.stage(copyingFrom: source, as: mediaId, ext: "jpg")
        // Read off the staged copy, which is what the extension does — by then the URL the share
        // sheet handed over has already been deleted.
        let stagedURL = try #require(inbox.mediaURL(for: PendingShare.Item(
            id: mediaId, filename: staged.filename, kind: .photo, byteCount: 0, capturedAt: nil
        )))
        let capturedAt = try #require(
            ImagePipeline.exifDate(fileAt: stagedURL),
            "the EXIF date did not survive the copy into the container"
        )

        let now = Date()
        let resolved = PendingShare.resolveOccurredAt(captures: [capturedAt], now: now)

        #expect(resolved.source == .captureMetadata)
        #expect(resolved.date == capturedAt)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: resolved.date)
        #expect(parts.year == 2019)
        #expect(parts.month == 7)
        #expect(parts.day == 4)
        #expect(!calendar.isDate(resolved.date, inSameDayAs: now), "a 2019 photo was filed under today")
    }

    /// **The timezone fixture.**
    ///
    /// EXIF carries no zone: `2019:07:04 23:30:00` is wall-clock time where the photo was taken,
    /// and the honest reading is the device's zone. This pins that, and pins the divergence it
    /// creates: on any device not sitting at UTC, that same instant is a *different day* in UTC —
    /// so a build that read EXIF as UTC would file this photo on 4 July or 5 July depending on
    /// which side of Greenwich the parent lives, and the assertion below is what fails when it
    /// does.
    @Test("EXIF is read as wall clock in the device's zone, not as UTC")
    func exifIsWallClockNotUTC() throws {
        let source = try sourceFile(imageData(dateTimeOriginal: "2019:07:04 23:30:00"))
        defer { try? FileManager.default.removeItem(at: source) }

        let captured = try #require(ImagePipeline.exifDate(fileAt: source))
        let resolved = PendingShare.resolveOccurredAt(captures: [captured], now: Date())

        func wallClock(_ date: Date, in zone: TimeZone) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return String(format: "%04d-%02d-%02d %02d:%02d",
                          p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
        }

        #expect(
            wallClock(resolved.date, in: .current) == "2019-07-04 23:30",
            "the wall clock on the file is not the wall clock in the device's zone"
        )

        let utc = try #require(TimeZone(identifier: "UTC"))
        let offset = TimeZone.current.secondsFromGMT(for: resolved.date)
        if offset != 0 {
            #expect(
                wallClock(resolved.date, in: utc) != "2019-07-04 23:30",
                "this fixture is meant to diverge from UTC; if it does not, the parse ignored the zone"
            )
        }
        // Whatever the runner's zone, the date is the file's and not the calendar's.
        #expect(!Calendar.current.isDateInToday(resolved.date))
    }

    // MARK: What may be shared

    /// **An unsupported type never reaches the staging queue.**
    ///
    /// The plist's activation rule is what stops the extension being offered at all; this is the
    /// second gate, over whatever an item provider turns out to be carrying.
    @Test("only images and videos resolve to a kind")
    func refusesUnsupportedTypes() {
        #expect(ShareMediaKind.resolve(.jpeg) == .photo)
        #expect(ShareMediaKind.resolve(.heic) == .photo)
        #expect(ShareMediaKind.resolve(.png) == .photo)
        #expect(ShareMediaKind.resolve(.gif) == .photo)
        #expect(ShareMediaKind.resolve(.rawImage) == .photo)
        #expect(ShareMediaKind.resolve(.quickTimeMovie) == .video)
        #expect(ShareMediaKind.resolve(.mpeg4Movie) == .video)
        #expect(ShareMediaKind.resolve(.movie) == .video)

        for refused in [UTType.url, .fileURL, .plainText, .utf8PlainText, .pdf, .html,
                        .zip, .json, .vCard, .contact, .audio, .mp3, .folder, .data, .item] {
            #expect(
                ShareMediaKind.resolve(refused) == nil,
                "\(refused.identifier) reached the staging queue"
            )
        }
    }

    /// **A Live Photo stages as its still image, and this is what makes that true.**
    ///
    /// `com.apple.live-photo` does **not** conform to `public.image` — checked against the real
    /// type system rather than assumed, because the whole Live Photo story rests on it. A provider
    /// for one registers `public.jpeg` alongside it, so `ShareItemLoader.acceptedType` scans past
    /// the live-photo type and takes the still, which is the only shape the archive has for it.
    ///
    /// If this ever starts returning `.photo`, a Live Photo would stage as a bundle that
    /// `ImagePipeline` cannot read, and the share would silently lose its photo.
    @Test("a Live Photo is not itself an image; the still beside it is")
    func livePhotoIsNotAnImage() {
        #expect(ShareMediaKind.resolve(.livePhoto) == nil)
        #expect(ShareMediaKind.resolve(.jpeg) == .photo)
    }

    /// A real camera roll and a real share sheet carry more than JPEG and QuickTime, and the
    /// activation rule offers this extension anything conforming to image or movie. These are the
    /// ones that actually turn up, resolved as they were measured.
    ///
    /// Two of them are accepted and then fail conversion, on purpose rather than by oversight:
    /// an SVG conforms to `public.image` and `CGImageSource` will not read one, and a
    /// DRM-protected movie is not exportable. Both are skipped by the drain with the rest of the
    /// share intact — `oneBadFileDoesNotSinkTheShare` is that guarantee. Refusing them earlier
    /// would mean maintaining a denylist that goes stale.
    @Test("the formats a real share sheet actually offers")
    func realWorldTypes() {
        for photo in [UTType.heic, .heif, .tiff, .bmp, .webP, .rawImage, .svg] {
            #expect(ShareMediaKind.resolve(photo) == .photo, "\(photo.identifier)")
        }
        for video in [UTType.quickTimeMovie, .mpeg4Movie, .avi, .mpeg2Video,
                      .appleProtectedMPEG4Video] {
            #expect(ShareMediaKind.resolve(video) == .video, "\(video.identifier)")
        }
        // The abstract parent of both branches resolves to neither — a provider carrying only
        // `public.audiovisual-content` tells us nothing about which pipeline to use.
        #expect(ShareMediaKind.resolve(.audiovisualContent) == nil)
    }

    /// The plist is the real gate, so the plist is what is asserted — not a second copy of the
    /// claim written in Swift. It is a resource of this test bundle for exactly this reason.
    ///
    /// **The omissions are the substance.** Keys that are absent default to zero, which is what
    /// refuses web pages, text and arbitrary files; a test that only checked the two present keys
    /// would pass on a plist that also accepted everything else.
    @Test("the shipped activation rule accepts images and movies and nothing else")
    func activationRuleIsNarrow() throws {
        let bundle = Bundle(for: BundleAnchor.self)
        let url = try #require(
            bundle.url(forResource: "RascalShare-Info", withExtension: "plist"),
            "the extension's Info.plist is not a resource of the test bundle"
        )
        let plist = try #require(
            PropertyListSerialization.propertyList(
                from: try Data(contentsOf: url), format: nil
            ) as? [String: Any]
        )
        let extensionDict = try #require(plist["NSExtension"] as? [String: Any])

        #expect(extensionDict["NSExtensionPointIdentifier"] as? String == "com.apple.share-services")

        let attributes = try #require(extensionDict["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(
            attributes["NSExtensionActivationRule"] as? [String: Any],
            "the rule is a predicate string — TRUEPREDICATE offers this extension for everything"
        )

        #expect((rule["NSExtensionActivationSupportsImageWithMaxCount"] as? Int ?? 0) > 0)
        #expect((rule["NSExtensionActivationSupportsMovieWithMaxCount"] as? Int ?? 0) > 0)

        for forbidden in [
            "NSExtensionActivationSupportsWebURLWithMaxCount",
            "NSExtensionActivationSupportsWebPageWithMaxCount",
            "NSExtensionActivationSupportsText",
            "NSExtensionActivationSupportsAttachmentsWithMaxCount",
            "NSExtensionActivationSupportsFileWithMaxCount",
        ] {
            #expect(rule[forbidden] == nil, "\(forbidden) widens the extension beyond photos and video")
        }
    }

    // MARK: The container

    /// Duplicated from `WidgetSnapshotStore` on purpose — giving a target that stages photos the
    /// widget's snapshot model would hand it the Home Screen's whole state — so the two constants
    /// are pinned together here instead.
    @Test("the inbox and the widget agree on which App Group they are in")
    func appGroupMatchesTheWidget() {
        #expect(ShareInbox.appGroupIdentifier == WidgetSnapshotStore.appGroupIdentifier)
    }

    @Test("an inbox with no container degrades to doing nothing, loudly")
    func noContainerIsRefused() {
        let inbox = ShareInbox(directory: nil)
        #expect(inbox.pending().isEmpty)
        #expect(inbox.recordsDirectory == nil)
        #expect(inbox.sweepOrphans() == 0)
        #expect(throws: ShareInbox.Failure.unavailable) { try inbox.write(record()) }
        #expect(throws: ShareInbox.Failure.unavailable) {
            try inbox.stage(copyingFrom: URL(filePath: "/dev/null"), as: UUID(), ext: "jpg")
        }
    }

    @Test("the extension's write and the app's read agree on a filename")
    func filenameIsOneRule() throws {
        let inbox = temporaryInbox()
        let mediaId = UUID()
        let source = try sourceFile(imageData())
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try inbox.stage(copyingFrom: source, as: mediaId, ext: "JPG")
        #expect(staged.filename == "\(mediaId.uuidString.lowercased()).jpg")

        let one = PendingShare.Item(
            id: mediaId, filename: staged.filename, kind: .photo,
            byteCount: staged.byteCount, capturedAt: nil
        )
        let url = try #require(inbox.mediaURL(for: one))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(staged.byteCount > 0)
    }

    /// A copy is not atomic, so it lands under a dot-prefixed name and is renamed into place.
    /// Nothing partially written may ever sit under the name a record will point at.
    @Test("staging leaves no partial file behind under the real name")
    func stagingLeavesNoPartial() throws {
        let inbox = temporaryInbox()
        let mediaId = UUID()
        let source = try sourceFile(imageData())
        defer { try? FileManager.default.removeItem(at: source) }

        try inbox.stage(copyingFrom: source, as: mediaId, ext: "jpg")

        let mediaDirectory = try #require(inbox.mediaDirectory)
        let contents = try FileManager.default.contentsOfDirectory(
            at: mediaDirectory, includingPropertiesForKeys: nil
        )
        #expect(contents.count == 1)
        #expect(contents.allSatisfy { !$0.lastPathComponent.hasSuffix(".partial") })
    }

    /// Re-staging the same id replaces it, and a re-stage that **fails** leaves what was already
    /// there untouched. The second half is the one worth having: clearing the destination before
    /// the copy would mean a failed re-stage had destroyed a good photo to make room for nothing.
    @Test("re-staging replaces, and a failed re-stage destroys nothing")
    func reStagingIsNotDestructive() throws {
        let inbox = temporaryInbox()
        let mediaId = UUID()
        let first = try sourceFile(imageData(dateTimeOriginal: "2019:07:04 14:30:00"))
        defer { try? FileManager.default.removeItem(at: first) }

        let staged = try inbox.stage(copyingFrom: first, as: mediaId, ext: "jpg")
        let url = try #require(inbox.mediaURL(for: PendingShare.Item(
            id: mediaId, filename: staged.filename, kind: .photo, byteCount: 0, capturedAt: nil
        )))
        let original = try Data(contentsOf: url)

        // A replacement that succeeds.
        let second = try sourceFile(imageData(dateTimeOriginal: "2021:01:02 09:00:00"))
        defer { try? FileManager.default.removeItem(at: second) }
        try inbox.stage(copyingFrom: second, as: mediaId, ext: "jpg")
        #expect(ImagePipeline.exifDate(fileAt: url) != ImagePipeline.exifDate(fileAt: first))

        // A replacement that fails. The staged file must survive it intact.
        let missing = URL.temporaryDirectory.appending(path: "gone-\(UUID().uuidString).jpg")
        #expect(throws: ShareInbox.Failure.copyFailed) {
            try inbox.stage(copyingFrom: missing, as: mediaId, ext: "jpg")
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "a failed re-stage deleted the staged file")
        #expect(try Data(contentsOf: url).count > 0)
        #expect(original.count > 0)

        // And no `.partial` litter from the failure.
        let contents = try FileManager.default.contentsOfDirectory(
            at: #require(inbox.mediaDirectory), includingPropertiesForKeys: nil
        )
        #expect(contents.allSatisfy { !$0.lastPathComponent.hasSuffix(".partial") })
    }

    @Test("a source that is not there fails rather than staging an empty file")
    func missingSourceFails() {
        let inbox = temporaryInbox()
        let missing = URL.temporaryDirectory.appending(path: "gone-\(UUID().uuidString).jpg")
        #expect(throws: ShareInbox.Failure.copyFailed) {
            try inbox.stage(copyingFrom: missing, as: UUID(), ext: "jpg")
        }
    }

    // MARK: Orphans

    /// A share cancelled, or an extension killed between copying bytes and writing its record.
    /// Nothing will ever pick these up otherwise.
    @Test("bytes no record names are collected, and bytes a record names are not")
    func sweepsOrphansOnly() throws {
        let inbox = temporaryInbox()
        let kept = UUID()
        let orphan = UUID()
        let source = try sourceFile(imageData())
        defer { try? FileManager.default.removeItem(at: source) }

        let keptFile = try inbox.stage(copyingFrom: source, as: kept, ext: "jpg")
        try inbox.stage(copyingFrom: source, as: orphan, ext: "jpg")
        try inbox.write(record(media: [PendingShare.Item(
            id: kept, filename: keptFile.filename, kind: .photo,
            byteCount: keptFile.byteCount, capturedAt: nil
        )]))

        #expect(inbox.sweepOrphans() == 1)

        let mediaDirectory = try #require(inbox.mediaDirectory)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: mediaDirectory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(remaining == [keptFile.filename])
    }

    /// **A record this build cannot read still names files, and their names are unreachable.**
    /// Sweeping while one exists would delete the media belonging to a record a newer build wrote,
    /// which is the one deletion in this feature that could destroy a photo.
    @Test("nothing is swept while an unreadable record is present")
    func refusesToSweepPastAnUnreadableRecord() throws {
        let inbox = temporaryInbox()
        let source = try sourceFile(imageData())
        defer { try? FileManager.default.removeItem(at: source) }

        try inbox.stage(copyingFrom: source, as: UUID(), ext: "jpg")
        try inbox.write(PendingShare(
            version: PendingShare.currentVersion + 1,
            id: UUID(), createdAt: Date(), occurredAt: Date(),
            occurredAtSource: .shareTime, note: nil, media: [item()]
        ))

        #expect(inbox.sweepOrphans() == 0, "a newer build's media was swept out from under it")
    }

    /// "No records" and "cannot see the records directory" are the same empty array from here,
    /// and the second must never be read as permission to delete a parent's photos.
    @Test("an inbox that was never written to sweeps nothing")
    func sweepIsGuardedOnReachability() {
        #expect(temporaryInbox().sweepOrphans() == 0)
    }

    @Test("removing a share takes its record and its files")
    func removeTakesBoth() throws {
        let inbox = temporaryInbox()
        let mediaId = UUID()
        let source = try sourceFile(imageData())
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try inbox.stage(copyingFrom: source, as: mediaId, ext: "jpg")
        let one = PendingShare.Item(
            id: mediaId, filename: staged.filename, kind: .photo,
            byteCount: staged.byteCount, capturedAt: nil
        )
        let written = record(media: [one])
        try inbox.write(written)

        inbox.remove(written)

        #expect(inbox.pending().isEmpty)
        let url = try #require(inbox.mediaURL(for: one))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Memory

    /// **A large file is staged without being read into memory, measured rather than assumed.**
    ///
    /// A share extension runs under a hard memory ceiling and a 4K minute is ~250MB.
    /// `loadDataRepresentation` and `Data(contentsOf:)` are both one line away and both get this
    /// process killed; `FileManager.copyItem` hands the work to the kernel and stays flat.
    ///
    /// The instrument is checked first, against an allocation whose size is known, so a run where
    /// `phys_footprint` reports nothing fails here rather than passing the real assertion for the
    /// wrong reason.
    ///
    /// The fixture is opaque bytes with a `.mov` extension, and that is honest: staging is a byte
    /// copy and does not read content. What is being measured is that the copy does not scale with
    /// the file.
    @Test("a large video is staged without loading it into memory")
    func stagingDoesNotScaleWithFileSize() throws {
        let size = 160
        let inbox = temporaryInbox()
        let source = try makeLargeFile(megabytes: size)
        defer { try? FileManager.default.removeItem(at: source) }

        // 1. **The instrument, checked against an allocation of known size.** Without this the
        //    assertion below could pass because nothing is being measured at all, which is the
        //    likeliest way a memory test rots into decoration.
        let ballastPeak = peakFootprint {
            var ballast: Data? = Data(repeating: 0x11, count: 64 << 20)
            // Touched at both ends so the pages are resident rather than lazily mapped.
            ballast?[0] = 0x22
            ballast?[(64 << 20) - 1] = 0x22
            _ = ballast?.count
            ballast = nil
        }
        #expect(
            ballastPeak > 32 << 20,
            "phys_footprint is not responding to a 64MB allocation, so nothing below is measured"
        )

        // 2. **The real one, sampled rather than bracketed.** A before-and-after pair misses a
        //    spike already released by the time the second reading is taken, and that is exactly
        //    the shape of "read it all in, write it all out".
        var staged: ShareInbox.Staged?
        let peak = peakFootprint {
            staged = try? inbox.stage(copyingFrom: source, as: UUID(), ext: "mov")
        }

        #expect(staged?.byteCount == size << 20, "the whole file did not land")
        #expect(
            peak < 40 << 20,
            "staging peaked \(peak >> 20)MB above baseline for a \(size)MB file, which is what materialising it looks like"
        )
    }

    /// How far above its starting point the process's footprint rose while `work` ran.
    ///
    /// **A peak, sampled on another thread.** `phys_footprint` is what the kernel charges this
    /// process and what a jetsam kill is decided on, and a spike freed before the work returns
    /// still counted against the ceiling while it existed — so one reading before and one after is
    /// not a measurement of the thing that kills a share extension.
    ///
    /// A limit worth stating rather than hiding, because it was found by mutating the
    /// implementation rather than reasoned about: this **cannot see a memory-mapped read**.
    /// Replacing the copy with `Data(contentsOf:)` does not move this number, because Foundation
    /// maps a file that size instead of reading it and mapped clean pages are not charged. That is
    /// a limit of the instrument and equally a limit of the danger — the ceiling this test exists
    /// to protect is enforced on the same number this reads. What it does catch is anything that
    /// *materialises* the bytes: `loadDataRepresentation`, a chunked read into a growing buffer, a
    /// `[UInt8]` conversion. That is the family of mistakes that actually gets the process killed,
    /// and `ShareItemLoader` is written against it.
    private func peakFootprint(_ work: () -> Void) -> Int {
        let sampler = FootprintSampler(baseline: Self.readFootprint())
        sampler.start()
        work()
        return sampler.stop()
    }

    /// Samples `phys_footprint` off the calling thread. A reference type with a lock rather than a
    /// captured `var`, for the reason `WidgetSnapshotWriteTests.ReloadSpy` is one: the sampling
    /// closure is `@Sendable` and mutating a local from inside one is an error under the Swift 6
    /// language mode.
    private final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0
        private var running = true
        private let baseline: Int

        init(baseline: Int) { self.baseline = baseline }

        func start() {
            Thread.detachNewThread { [self] in
                while isRunning {
                    record(ShareInboxTests.readFootprint() - baseline)
                    usleep(300)
                }
            }
        }

        func stop() -> Int {
            lock.lock(); running = false; lock.unlock()
            // One last reading here, in case the work finished inside a single sample gap.
            record(ShareInboxTests.readFootprint() - baseline)
            return currentPeak
        }

        private var isRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return running
        }

        private var currentPeak: Int {
            lock.lock(); defer { lock.unlock() }
            return peak
        }

        private func record(_ value: Int) {
            lock.lock(); defer { lock.unlock() }
            peak = max(peak, value)
        }
    }

    /// Written in chunks so building the fixture is not itself the thing that blows the budget,
    /// and in its own function so the chunk is released before anything is measured.
    private func makeLargeFile(megabytes: Int) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "big-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0x5A, count: 8 << 20)
        for _ in 0..<(megabytes / 8) {
            try handle.write(contentsOf: chunk)
        }
        return url
    }

    /// `phys_footprint` — what the kernel actually charges this process, and what a jetsam kill is
    /// decided on. Resident size alone misses compressed and purgeable pages.
    ///
    /// `nonisolated static` so the sampler thread can call it: this suite is `@MainActor`, and a
    /// sampler that had to hop to the main actor to take a reading would be sampling a thread the
    /// work is blocking.
    nonisolated static func readFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
