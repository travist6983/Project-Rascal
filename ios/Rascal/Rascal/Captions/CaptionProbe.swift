import Foundation
import MediaAccessibility
import Photos

/// Answers one question, once: **do the photos on this phone already carry captions?**
///
/// Phase 33's device half has no API to call. `FoundationModels`' entire input vocabulary is
/// `Transcript.Segment` — text or structure — so there is no pixels-to-prose call, and
/// `docs/blocked.md` §9 carries the grep that re-checks it. The one thing that *does* exist is
/// `MAImageCaptioningCopyCaption`, and it is a **metadata accessor, not a model**: it reads the
/// XMP field `Iptc4xmpExt:AOContentDescription` and returns nil when nobody wrote one.
///
/// That makes the whole feature rest on a number nobody has measured — what fraction of a real
/// camera roll has that field set. If it is near zero, shipping the device half produces a queue
/// that is permanently empty and a Settings row that reads "0 waiting" forever, which is the
/// furniture this app refuses. **So this measures first, and the phase is decided after.** It is a
/// diagnostic, not a feature: it writes nothing, uploads nothing, and persists nothing.
///
/// **Nothing here is a caption pipeline and this file must not grow into one.** If the number
/// comes back worth building on, the writer belongs in a phase with a caption state ladder, a
/// provenance distinction and the clobber guard that comes with having a writer at all — see
/// `docs/decisions.md`. If it comes back near zero, this file is deleted and 33 closes.
/// `nonisolated` because the work happens off the main actor. The project builds with
/// main-actor-by-default isolation, so without this every static member here — the ceilings,
/// `caption(at:)`, and `Report`'s memberwise init — is `@MainActor`, and the detached task in
/// `run()` cannot touch any of them. Same reason `ExtractedDetails` carries it.
nonisolated enum CaptionProbe {
    /// What the probe found. Plain data, so the report view holds no PhotoKit objects.
    struct Report: Equatable, Sendable {
        /// Photos considered — on-device images, newest first, up to `sampleCeiling`.
        var scanned = 0
        /// Assets skipped because their bytes are in iCloud and not on this phone.
        var skippedInCloud = 0
        /// Assets whose original could not be reached at all. Counted, never fatal.
        var unreadable = 0
        /// Photos carrying a non-empty `Iptc4xmpExt:AOContentDescription`.
        var hits = 0
        /// A few of the captions themselves, so the number can be judged rather than just read.
        var samples: [String] = []
        /// The sample came from a selection rather than the library.
        ///
        /// **The number this probe exists to produce is a rate over a real camera roll**, and a
        /// rate measured over a handful of deliberately shared photos is not that — it is a
        /// different, much smaller question wearing the same percentage sign. Recorded so the
        /// report can say which one it answered, per the same rule `AddToArchiveSheet` states for
        /// month totals.
        var limitedLibrary = false

        /// Hits as a share of what was actually read. Nil when nothing was read, because a rate
        /// with a zero denominator is not zero — it is unmeasured, and the two must not render
        /// the same way.
        var hitRate: Double? {
            let read = scanned - unreadable
            guard read > 0 else { return nil }
            return Double(hits) / Double(read)
        }
    }

    /// Bounded on purpose. A library of 40,000 photos does not need to be walked to answer
    /// "roughly never, or roughly sometimes", and an unbounded diagnostic is one somebody
    /// cancels rather than finishes.
    static let sampleCeiling = 500

    /// At most this many example captions are kept. Enough to judge quality, few enough that the
    /// report stays a screen rather than a list.
    static let sampleCeilingForExamples = 5

    /// Truncation for an example. A caption is a sentence; anything longer is a document and the
    /// point here is the shape, not the contents.
    static let sampleLength = 140

    /// Walk the camera roll and count.
    ///
    /// **iCloud-only assets are counted and never fetched**, the same rule `BackfillScanner`
    /// follows: `isNetworkAccessAllowed = false` means a photo whose bytes live in iCloud fails
    /// locally instead of pulling a gigabyte over cellular for a diagnostic nobody asked to pay
    /// for. They are reported separately rather than folded into the denominator, because
    /// "we could not look" and "we looked and found nothing" are different answers.
    static func run(
        ceiling: Int = sampleCeiling,
        authorization: @Sendable () async -> BackfillAuthorization = { await currentAuthorization() }
    ) async throws -> Report {
        // **The one thing in this file that is not a diagnostic detail.** `PHAsset.fetchAssets`
        // against an unauthorized library does not fail — it returns an empty result — so without
        // this the screen reported "0 photos read, not measured" as though it had looked, which is
        // the wrong answer to the only question the probe exists to ask, and it would have been
        // written down as a real one.
        let granted = await authorization()
        guard granted.canScan else { throw ProbeError.notAuthorized(granted) }
        let limited = granted == .limited

        // Detached with an explicit cancellation handler, for the reason `BackfillScanner`
        // documents: a detached task inherits nothing from its creator, cancellation included,
        // and awaiting `.value` does not forward it either. Without this the Cancel button
        // stops nothing and the walk keeps running behind a dismissed screen.
        let work = Task.detached(priority: .utility) {
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .image, options: options)

            var report = Report()
            report.limitedLibrary = limited
            var candidates: [PHAsset] = []

            assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                guard candidates.count < ceiling else { stop.pointee = true; return }
                if isOnDevice(asset) {
                    candidates.append(asset)
                } else {
                    report.skippedInCloud += 1
                }
            }
            if Task.isCancelled { throw CancellationError() }

            for asset in candidates {
                if Task.isCancelled { throw CancellationError() }
                report.scanned += 1
                guard let url = await originalURL(for: asset) else {
                    report.unreadable += 1
                    continue
                }
                guard let caption = caption(at: url) else { continue }
                report.hits += 1
                if report.samples.count < sampleCeilingForExamples {
                    report.samples.append(String(caption.prefix(sampleLength)))
                }
            }
            return report
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Why a run produced nothing.
    nonisolated enum ProbeError: Error, Equatable {
        /// The library has not been opened to this app. **Not something this screen may fix**: see
        /// `currentAuthorization`.
        ///
        /// It carries the grant, because *"never asked"* and *"said no"* are different answers and
        /// the screen owes the parent the right sentence for the one they are in.
        case notAuthorized(BackfillAuthorization)
    }

    /// What the library will let this probe see.
    ///
    /// **Read through the app's one photo-authorization authority, and read only — never
    /// requested.** iOS shows its prompt once and a denial is close to permanent, so the app has
    /// exactly one screen allowed to spend it, `BackfillPermissionScreen`, which earns it with an
    /// explainer first. A diagnostic buried three taps into Settings must not be the thing that
    /// burns that single ask on a parent who was looking for something else entirely.
    static func currentAuthorization() async -> BackfillAuthorization {
        await PhotoLibraryBackfillSource().authorization()
    }

    /// The caption already embedded in a file, or nil.
    ///
    /// **Whitespace-only counts as absent.** A field that exists and says nothing is not a
    /// caption, and counting it as a hit would inflate the one number this whole exercise is
    /// for. Non-private so the unit tests can drive it against fixture files on disk — the walk
    /// above needs a camera roll, this does not.
    static func caption(at url: URL) -> String? {
        var error: CFError?
        guard let raw = MAImageCaptioningCopyCaption(url as CFURL, &error) else { return nil }
        let trimmed = (raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A file URL for the asset's original, without copying its bytes.
    ///
    /// `requestContentEditingInput` hands back `fullSizeImageURL`, which points at the original
    /// already on disk — no export, no second copy, and nothing written anywhere. The alternative
    /// (`PHAssetResourceManager.writeData`) duplicates every photo into a temp file to read one
    /// metadata field, which for five hundred photos is a disk full for no reason.
    private static func originalURL(for asset: PHAsset) async -> URL? {
        let options = PHContentEditingInputRequestOptions()
        // No network. See `run` — a diagnostic must not pull iCloud originals.
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            let latch = ResumeOnce(continuation)
            asset.requestContentEditingInput(with: options) { input, _ in
                latch.resume(input?.fullSizeImageURL)
            }
        }
    }

    /// Metadata only — `PHAssetResource` describes what exists without asking for the bytes, so
    /// this never triggers an iCloud download. Same shape as `BackfillScanner.isOnDevice`.
    private static func isOnDevice(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return false }
        return resources.contains { resource in
            (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
        }
    }
}

/// One-shot latch for a PhotoKit callback.
///
/// `requestContentEditingInput` is documented to call its handler once, and a continuation
/// resumed twice is a crash rather than a warning. PhotoKit has form here — the same guard exists
/// in `BackfillScanner` for `requestImageDataAndOrientation`, which *does* call back twice when
/// it serves a degraded image first.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?

    init(_ continuation: CheckedContinuation<URL?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: URL?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
