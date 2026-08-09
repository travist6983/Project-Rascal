import AVFoundation
import Foundation

/// Getting at the bytes themselves, for a screen that shows one entry rather than five hundred.
///
/// `ThumbnailStore` is a bounded cache for list rows. This is the other half: full-size pixels
/// for the fullscreen viewer, and a URL AVPlayer can open for a video or a voice note. Neither is
/// cached to disk — a full-size copy of every photo ever opened would grow without bound, and the
/// thumbnail already covers the case that repeats.
///
/// **The signed URL is minted per use and never stored.** It outlives its signature, and a stored
/// one fails later in a way that reads like the archive lost the file. Cache the bytes, refetch
/// the URL.
nonisolated enum MediaAccess {

    /// Full-size bytes: the staged original if this phone still has it, otherwise storage.
    ///
    /// The local copy is checked first because it is free and identical — the staging sweep only
    /// removes an original once the server has acknowledged it, so a file that is still here is
    /// the same file that is there.
    static func fullImageData(mediaId: UUID, localFile: URL?, api: APIClient) async -> Data? {
        if let localFile, let data = try? Data(contentsOf: localFile, options: .mappedIfSafe) {
            return data
        }
        guard let url = await signedURL(mediaId: mediaId, api: api),
              let (bytes, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return bytes
    }

    /// Something `AVPlayer` can open — a file on disk, or a short-lived URL into storage.
    ///
    /// Streaming rather than downloading is the whole reason this returns a URL instead of
    /// bytes: a minute of 1080p is about seventy megabytes, and pulling all of it into memory
    /// before the first frame plays is how a detail screen gets killed.
    static func playbackURL(mediaId: UUID, localFile: URL?, api: APIClient) async -> URL? {
        if let localFile, FileManager.default.fileExists(atPath: localFile.path) {
            return localFile
        }
        return await signedURL(mediaId: mediaId, api: api)
    }

    /// A poster frame for a video this phone did not record.
    ///
    /// The timeline will not do this — pulling a hundred megabytes to draw a 56pt square is not
    /// a trade worth making on someone's cellular plan. **Entry Detail is different**: the parent
    /// has opened this one entry and the next thing they will do is press play, which downloads
    /// the video regardless. So the cost is borrowed rather than added, and it buys a frame of
    /// their child instead of a tinted rectangle.
    ///
    /// `AVAssetImageGenerator` reads over ranged HTTP, so it takes the first moments of the file
    /// rather than the whole thing. The result is written to the same staging cache the composer
    /// uses, so it happens once per video, ever — and the timeline picks it up from disk after.
    static func posterFrame(
        mediaId: UUID,
        localFile: URL?,
        api: APIClient,
        staging: StagingStore
    ) async -> Data? {
        guard let url = await playbackURL(mediaId: mediaId, localFile: localFile, api: api) else {
            return nil
        }
        // `try?` over a throwing function that already returns `Data?` flattens to one optional.
        guard let data = try? await VideoPipeline.posterFrame(for: AVURLAsset(url: url)) else {
            return nil
        }

        do { try staging.stageThumbnail(data, for: mediaId) } catch {}
        return data
    }

    /// Why a bulk fetch did not happen, when the difference matters to what gets said about it.
    nonisolated enum FetchFailure: Error, Equatable {
        /// The network this phone is on is cellular, a personal hotspot, or in Low Data Mode.
        /// **Not an error** — a deferral, and the row is retried on a better connection.
        case networkTooExpensive
        /// Anything else: offline, a 403 on a stale signature, a 409 on an unfinished upload.
        case unreachable
    }

    /// A session for **bulk backfill**, which refuses to run on a network the user pays by the
    /// megabyte for.
    ///
    /// This is the only place in the app that downloads media the parent did not ask to look at.
    /// A backlog run is hundreds of files at once, kicked off by someone who pressed a button
    /// about *transcribing* — they did not consent to a few hundred megabytes of cellular data,
    /// and the app must not read one button as permission for the other. The same reasoning that
    /// keeps the backlog manual for the battery keeps it off cellular for the data.
    ///
    /// Both flags together: `expensive` covers cellular and hotspots, `constrained` covers Low
    /// Data Mode, which a parent turns on precisely to stop this class of thing.
    ///
    /// **Nothing on the ordinary path goes through here.** A recording made on this phone is read
    /// from its staged original and never downloaded at all, so this affects backfill of rows that
    /// came from another device and nothing else.
    private static let backfillSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: configuration)
    }()

    /// The bytes **on disk**, wherever they have to come from.
    ///
    /// Distinct from `playbackURL`, which is happy to hand back a remote URL because `AVPlayer`
    /// streams. Transcription cannot: `AVAudioFile` reads a file and nothing else, so a recording
    /// this phone did not make has to be fetched before it can be read.
    ///
    /// Written to `destination` and owned by the caller from then on — including deleting it,
    /// which is why this does not put it in the staging store: staging is where files waiting to
    /// upload live, and this one is going the other way.
    static func downloadToFile(
        mediaId: UUID,
        destination: URL,
        api: APIClient
    ) async -> Result<URL, FetchFailure> {
        guard let url = await signedURL(mediaId: mediaId, api: api) else { return .failure(.unreachable) }

        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await backfillSession.download(from: url)
        } catch let error as URLError where error.networkUnavailableReason != nil {
            // The radio said no on purpose. Told apart from a real failure so the row can say
            // "waiting for Wi-Fi" rather than implying the recording is lost.
            return .failure(.networkTooExpensive)
        } catch {
            return .failure(.unreachable)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .failure(.unreachable)
        }

        // `download(from:)` puts the file somewhere the system reclaims the moment this returns,
        // so it is moved rather than read. Any previous attempt's leftovers go first — a move
        // onto an existing path fails, and failing there would look like a network problem.
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: temporary, to: destination)) != nil else {
            return .failure(.unreachable)
        }
        return .success(destination)
    }

    /// `409 upload_incomplete` is the one failure worth naming: the row exists and its bytes do
    /// not, which is an unfinished upload rather than a lost file. Everything else is nil, and
    /// the view says so in its own words.
    private static func signedURL(mediaId: UUID, api: APIClient) async -> URL? {
        guard let raw = try? await api.mediaDownloadURL(mediaId: mediaId) else { return nil }
        return URL(string: raw)
    }
}
