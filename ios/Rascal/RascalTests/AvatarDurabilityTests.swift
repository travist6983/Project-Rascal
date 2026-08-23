import Foundation
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#endif

@testable import Rascal

// MARK: - Stubs

/// The two transfers that do not go through `APIClient`, recorded rather than performed.
///
/// Locking is confined to synchronous helpers, the same shape `StubPerformer` uses and for the
/// same reason: taking a lock directly inside an `async` function is a warning about shape, and
/// this lane treats a warning as a defect.
final class StubAvatarTransfer: AvatarTransferring, @unchecked Sendable {
    struct Sent: Equatable, Sendable {
        let url: String
        let contentType: String
        let bytes: Data
    }

    enum Failure: Error, Equatable {
        case offline
        /// What storage answers for a key whose object is gone. Distinct from `offline` because
        /// they are different facts, even though the client renders both as no picture.
        case notFound
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var _fetched: [String] = []
    private var _putFailure: Failure?
    private var _getFailure: Failure?
    private var _payload = Data("bytes-from-storage".utf8)

    var sent: [Sent] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    var fetched: [String] {
        lock.lock(); defer { lock.unlock() }
        return _fetched
    }

    var putFailure: Failure? {
        get { lock.lock(); defer { lock.unlock() }; return _putFailure }
        set { lock.lock(); defer { lock.unlock() }; _putFailure = newValue }
    }

    var getFailure: Failure? {
        get { lock.lock(); defer { lock.unlock() }; return _getFailure }
        set { lock.lock(); defer { lock.unlock() }; _getFailure = newValue }
    }

    var payload: Data {
        get { lock.lock(); defer { lock.unlock() }; return _payload }
        set { lock.lock(); defer { lock.unlock() }; _payload = newValue }
    }

    private func recordPut(_ item: Sent) -> Failure? {
        lock.lock(); defer { lock.unlock() }
        _sent.append(item)
        return _putFailure
    }

    private func recordGet(_ url: String) -> (Failure?, Data) {
        lock.lock(); defer { lock.unlock() }
        _fetched.append(url)
        return (_getFailure, _payload)
    }

    func put(_ data: Data, to url: URL, contentType: String) async throws {
        let failure = recordPut(
            Sent(url: url.absoluteString, contentType: contentType, bytes: data)
        )
        if let failure { throw failure }
    }

    func get(_ url: URL) async throws -> Data {
        let (failure, payload) = recordGet(url.absoluteString)
        if let failure { throw failure }
        return payload
    }
}

// MARK: - Fixtures

private let storagePutURL = "https://storage.example/children/put-target.jpg"
private let storageGetURL = "https://storage.example/children/get-target.jpg"
private let storedKey = "children/abc/avatar/def.jpg"

private func presignJSON(key: String = storedKey) -> Data {
    Data(#"{"upload_url":"\#(storagePutURL)","avatar_key":"\#(key)","expires_in":3600}"#.utf8)
}

private func readTicketJSON() -> Data {
    Data(#"{"url":"\#(storageGetURL)","expires_in":3600}"#.utf8)
}

/// `key` is optional so a *clear*'s response can be the row the server actually wrote — a child
/// whose `avatar_key` is now null. Interpolated the way `SettingsTests.userJSON` already writes a
/// nullable string, rather than by keeping a second near-identical fixture beside this one.
private func patchedChildJSON(_ id: UUID, key: String? = storedKey) -> Data {
    let avatarKey = key.map { "\"\($0)\"" } ?? "null"
    return Data(#"""
    {"id":"\#(id.uuidString.lowercased())","name":"Milo","birthdate":"2022-06-12",\#
    "pronouns":null,"avatar_key":\#(avatarKey),"family_timezone":"America/Denver",\#
    "created_at":"2026-08-12T01:06:30.309889Z","updated_at":"2026-08-12T01:07:09.268867Z"}
    """#.utf8)
}

private func refusedJSON(_ code: String, field: String) -> Data {
    Data(#"{"error":{"code":"\#(code)","message":"no","field":"\#(field)"}}"#.utf8)
}

/// Presign, PATCH and read-back all live under `/v1/children/`, and `StubPerformer` picks the
/// **last** matching rule — so the broad one is registered first and the specific ones after it.
@MainActor
private func wiredAPI(
    _ performer: StubPerformer,
    childId: UUID,
    patchStatus: Int = 200,
    presignStatus: Int = 200,
    readStatus: Int = 200
) -> APIClient {
    performer.on("/v1/children/") { _ in
        patchStatus == 200
            ? (patchedChildJSON(childId), 200)
            : (Data(#"{"error":{"code":"internal_error","message":"nope","field":null}}"#.utf8), patchStatus)
    }
    performer.on("avatar-upload-url") { _ in
        presignStatus == 200
            ? (presignJSON(), 200)
            : (refusedJSON("validation_failed", field: "content_type"), presignStatus)
    }
    performer.on("avatar-url") { _ in
        readStatus == 200
            ? (readTicketJSON(), 200)
            : (Data(#"{"error":{"code":"not_found","message":"Avatar not found","field":null}}"#.utf8), readStatus)
    }
    return APIClient(
        baseURL: URL(string: "http://localhost:8000/")!,
        performer: performer,
        tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
    )
}

private func paths(_ performer: StubPerformer) -> [String] {
    performer.requests.compactMap { $0.url?.path() }
}

// MARK: - Uploading

@Suite("Avatar durability — uploading")
@MainActor
struct AvatarUploadTests {

    @Test("the upload is presign, then PUT, then commit — and the commit is last")
    func theThreeStepsInOrder() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        let pending = InMemoryPendingAvatarUploadStore()
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store, pending: pending, transfer: transfer
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        let uploaded = await sync.sweep()

        #expect(uploaded == 1)
        let seen = paths(performer)
        #expect(seen.count == 2)
        #expect(seen[0].hasSuffix("avatar-upload-url"))
        // The commit is the *second* API call, after the bytes are in storage. A presign the
        // phone abandons must leave an orphaned object, never a child pointing at nothing.
        #expect(seen[1].hasSuffix(child.uuidString.lowercased()))
        #expect(transfer.sent.count == 1)
        #expect(transfer.sent[0].url == storagePutURL)
    }

    /// The single most common failure in presigned uploads, and it fails with an opaque 403.
    @Test("the PUT announces exactly the content type the presign was asked for")
    func contentTypeMatchesTheSignature() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: InMemoryAvatarStore(),
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: transfer
        )

        sync.enqueue(Data("jpeg".utf8), for: child, contentType: "image/heic")
        await sync.sweep()

        // What went out on the presign request…
        let presign = try #require(performer.requests.first { $0.url?.path().hasSuffix("avatar-upload-url") == true })
        let body = try #require(presign.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["content_type"] as? String == "image/heic")
        // …must be the same string that goes out on the PUT.
        #expect(transfer.sent[0].contentType == "image/heic")
    }

    @Test("a successful upload stops being outstanding")
    func successClearsTheRecord() async throws {
        let child = UUID()
        let pending = InMemoryPendingAvatarUploadStore()
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child),
            store: InMemoryAvatarStore(), pending: pending, transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        #expect(pending.pending(for: child) != nil)
        await sync.sweep()
        #expect(pending.pending(for: child) == nil)
    }

    @Test("the bytes are on disk before anything touches the network")
    func localWriteHappensFirst() async throws {
        let child = UUID()
        let store = InMemoryAvatarStore()
        let performer = StubPerformer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store,
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("jpeg".utf8), for: child)

        // Nothing has been swept yet, and the picture is already safe.
        #expect(store.load(for: child) == Data("jpeg".utf8))
        #expect(performer.requests.isEmpty)
    }
}

// MARK: - The invariant

/// **A failed upload never removes the local copy.** A parent who cropped an avatar on a train and
/// watched it appear must not watch it vanish when the network comes back wrong.
///
/// One test per step that can fail, because they fail in different places and a single test would
/// only prove whichever one it happened to exercise.
@Suite("Avatar durability — a failed upload never costs the picture")
@MainActor
struct AvatarSurvivesFailureTests {

    @Test("a refused presign leaves the local copy alone")
    func presignRefusedKeepsBytes() async throws {
        let child = UUID()
        let store = InMemoryAvatarStore()
        let pending = InMemoryPendingAvatarUploadStore()
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child, presignStatus: 422),
            store: store, pending: pending, transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        let uploaded = await sync.sweep()

        #expect(uploaded == 0)
        #expect(store.load(for: child) == Data("jpeg".utf8))
        // A 422 cannot be retried into working, so it stops being swept — but the picture stays.
        #expect(pending.pending(for: child) == nil)
    }

    @Test("a failed PUT leaves the local copy alone")
    func putFailedKeepsBytes() async throws {
        let child = UUID()
        let store = InMemoryAvatarStore()
        let transfer = StubAvatarTransfer()
        transfer.putFailure = .offline
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child),
            store: store, pending: InMemoryPendingAvatarUploadStore(), transfer: transfer
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        let uploaded = await sync.sweep()

        #expect(uploaded == 0)
        #expect(store.load(for: child) == Data("jpeg".utf8))
    }

    /// The step the brief names: force a 500 from the PATCH and confirm the picture survives.
    @Test("a failed commit leaves the local copy alone")
    func commitFailedKeepsBytes() async throws {
        let child = UUID()
        let store = InMemoryAvatarStore()
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child, patchStatus: 500),
            store: store, pending: InMemoryPendingAvatarUploadStore(), transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        let uploaded = await sync.sweep()

        #expect(uploaded == 0)
        #expect(store.load(for: child) == Data("jpeg".utf8))
    }

    @Test("a failed commit stays outstanding and is scheduled to try again")
    func commitFailedSchedulesRetry() async throws {
        let child = UUID()
        let pending = InMemoryPendingAvatarUploadStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child, patchStatus: 500),
            store: InMemoryAvatarStore(), pending: pending, transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        await sync.sweep(now: now)

        let record = try #require(pending.pending(for: child))
        #expect(record.attemptCount == 1)
        // Scheduled on the shared `UploadBackoff`, not on a policy of its own.
        let next = try #require(record.nextAttemptAt)
        #expect(next > now)
    }
}

// MARK: - Scheduling

@Suite("Avatar durability — when the sweep tries")
@MainActor
struct AvatarSweepSchedulingTests {

    @Test("a record that is not due yet is skipped")
    func notDueIsSkipped() async throws {
        let child = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        store.save(Data("jpeg".utf8), for: child)
        let pending = InMemoryPendingAvatarUploadStore([
            child: PendingAvatarUpload(
                childId: child, contentType: "image/jpeg", byteCount: 4,
                attemptCount: 1, nextAttemptAt: now.addingTimeInterval(60)
            ),
        ])
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store, pending: pending, transfer: StubAvatarTransfer()
        )

        let uploaded = await sync.sweep(now: now)

        #expect(uploaded == 0)
        #expect(performer.requests.isEmpty)
    }

    @Test("a record past the attempt ceiling stops being retried automatically")
    func exhaustedIsSkipped() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        store.save(Data("jpeg".utf8), for: child)
        let pending = InMemoryPendingAvatarUploadStore([
            child: PendingAvatarUpload(
                childId: child, contentType: "image/jpeg", byteCount: 4,
                attemptCount: UploadBackoff.maxAttempts, nextAttemptAt: nil
            ),
        ])
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store, pending: pending, transfer: StubAvatarTransfer()
        )

        #expect(await sync.sweep() == 0)
        #expect(performer.requests.isEmpty)
        // Still recorded, and the picture is still there. What stopped is the automatic retry.
        #expect(pending.pending(for: child) != nil)
        #expect(store.load(for: child) != nil)
    }

    @Test("a record whose bytes have gone is dropped rather than retried forever")
    func missingBytesClearTheRecord() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let pending = InMemoryPendingAvatarUploadStore([
            child: PendingAvatarUpload(childId: child, contentType: "image/jpeg", byteCount: 4),
        ])
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: InMemoryAvatarStore(), pending: pending, transfer: StubAvatarTransfer()
        )

        #expect(await sync.sweep() == 0)
        #expect(pending.pending(for: child) == nil)
        #expect(performer.requests.isEmpty)
    }
}

// MARK: - Reading it back

@Suite("Avatar durability — reading it back")
@MainActor
struct AvatarReadTests {

    @Test("a local copy is served without any request at all")
    func localHitMakesNoRequest() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        store.save(Data("on-disk".utf8), for: child)
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store, pending: InMemoryPendingAvatarUploadStore(), transfer: transfer
        )

        let data = await sync.avatarData(for: child, remoteKey: storedKey)

        #expect(data == Data("on-disk".utf8))
        #expect(performer.requests.isEmpty)
        #expect(transfer.fetched.isEmpty)
    }

    /// The point of carrying `avatar_key` on the launch path: no avatar costs nothing.
    @Test("a child with no avatar_key makes no request and renders no picture")
    func noKeyMakesNoRequest() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: InMemoryAvatarStore(),
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: StubAvatarTransfer()
        )

        #expect(await sync.avatarData(for: child, remoteKey: nil) == nil)
        #expect(performer.requests.isEmpty)
    }

    @Test("a cache miss fetches once, caches, and serves locally after that")
    func cacheMissFetchesThenCaches() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        let transfer = StubAvatarTransfer()
        transfer.payload = Data("from-storage".utf8)
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store, pending: InMemoryPendingAvatarUploadStore(), transfer: transfer
        )

        let first = await sync.avatarData(for: child, remoteKey: storedKey)
        #expect(first == Data("from-storage".utf8))
        #expect(transfer.fetched == [storageGetURL])
        #expect(store.load(for: child) == Data("from-storage".utf8))

        // The fresh-install path becoming the ordinary path: no second round trip.
        let second = await sync.avatarData(for: child, remoteKey: storedKey)
        #expect(second == Data("from-storage".utf8))
        #expect(transfer.fetched.count == 1)
        #expect(performer.requests.count == 1)
    }

    /// 404 is the documented answer for a child with no avatar. It is not a failure and nothing
    /// surfaces it.
    @Test("a 404 from the read route is a normal answer, not an error")
    func notFoundIsNormal() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child, readStatus: 404),
            store: InMemoryAvatarStore(),
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: StubAvatarTransfer()
        )

        // A key the server has since forgotten — the one case the 404 exists for.
        #expect(await sync.avatarData(for: child, remoteKey: storedKey) == nil)
    }

    /// **The realistic stale case, and it does not come back as a 404 from our route.**
    ///
    /// `presign_avatar_read` only checks whether `avatar_key IS NULL` — it never asks storage
    /// whether the object is still there. So a child pointing at a key whose object has gone gets
    /// **200 and a perfectly valid presigned URL**, and the 404 arrives from storage when the
    /// client follows it. Verified against the live API: `PATCH` a bogus key → `avatar-url` 200 →
    /// following that URL 404.
    ///
    /// The route-level 404 above is the *narrow* case (the key was cleared between `GET /children`
    /// and this read). This is the one that will actually happen.
    @Test("a key whose object has gone renders no picture and is not an error")
    func storageNotFoundIsNormal() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        let transfer = StubAvatarTransfer()
        // 200 from our route, 404 from storage — exactly what the live API does.
        transfer.getFailure = .notFound
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store, pending: InMemoryPendingAvatarUploadStore(), transfer: transfer
        )

        #expect(await sync.avatarData(for: child, remoteKey: storedKey) == nil)
        // Nothing cached, so a later launch tries again rather than caching an empty file.
        #expect(store.load(for: child) == nil)
    }

    @Test("an offline download is not cached and not an error")
    func offlineDownloadYieldsNothing() async throws {
        let child = UUID()
        let store = InMemoryAvatarStore()
        let transfer = StubAvatarTransfer()
        transfer.getFailure = .offline
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child),
            store: store, pending: InMemoryPendingAvatarUploadStore(), transfer: transfer
        )

        #expect(await sync.avatarData(for: child, remoteKey: storedKey) == nil)
        #expect(store.load(for: child) == nil)
    }
}

// MARK: - Surviving a relaunch

/// **The record is worthless if it does not survive the process**, which is the entire reason it
/// is written down rather than held in memory.
///
/// Worth testing rather than assuming: `UUID` is not `CodingKeyRepresentable`, so `JSONEncoder`
/// does not write `[UUID: V]` as a JSON object keyed by string — it writes a flat array of
/// alternating keys and values. That round-trips symmetrically, but it is the kind of thing that
/// would fail silently and take every pending avatar with it.
@Suite("Avatar durability — the pending record survives a relaunch")
struct PendingAvatarUploadStoreTests {

    private func freshDefaults() throws -> UserDefaults {
        let suite = "avatar.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test("a pending record round-trips through UserDefaults")
    func roundTrips() throws {
        let defaults = try freshDefaults()
        let child = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let record = PendingAvatarUpload(
            childId: child, contentType: "image/jpeg", byteCount: 38577,
            attemptCount: 3, nextAttemptAt: when
        )

        UserDefaultsPendingAvatarUploadStore(defaults: defaults).save(record)
        // A *different instance* reading the same defaults — i.e. the next launch.
        let reloaded = try #require(
            UserDefaultsPendingAvatarUploadStore(defaults: defaults).pending(for: child)
        )

        #expect(reloaded == record)
        #expect(reloaded.contentType == "image/jpeg")
        #expect(reloaded.attemptCount == 3)
        #expect(reloaded.nextAttemptAt == when)
    }

    @Test("two children keep separate records")
    func twoChildrenDoNotCollide() throws {
        let defaults = try freshDefaults()
        let store = UserDefaultsPendingAvatarUploadStore(defaults: defaults)
        let first = UUID(), second = UUID()

        store.save(PendingAvatarUpload(childId: first, contentType: "image/jpeg", byteCount: 1))
        store.save(PendingAvatarUpload(childId: second, contentType: "image/png", byteCount: 2))

        #expect(store.all().count == 2)
        #expect(store.pending(for: first)?.contentType == "image/jpeg")
        #expect(store.pending(for: second)?.contentType == "image/png")

        store.clear(for: first)
        #expect(store.pending(for: first) == nil)
        #expect(store.pending(for: second) != nil, "clearing one child must not clear the other")
    }

    @Test("clearing a child that was never recorded is harmless")
    func clearingAbsentIsHarmless() throws {
        let store = UserDefaultsPendingAvatarUploadStore(defaults: try freshDefaults())
        store.clear(for: UUID())
        #expect(store.all().isEmpty)
    }
}

// MARK: - What actually draws

#if canImport(UIKit)
/// **Pixels, not reasoning.** This project has no snapshot harness and its "view tests" test the
/// logic behind views rather than their output — so the claim "the avatar renders instead of the
/// initial" would otherwise be unverified all the way to a device.
///
/// `ImageRenderer` runs in the test target and produces real pixels, which is enough to prove the
/// branch is wired: a card given avatar bytes must not look like the same card without them, and
/// the picture must actually reach the disc.
@Suite("Avatar durability — what actually draws")
@MainActor
struct AvatarRenderingTests {

    /// A solid-colour JPEG, so a rendered pixel can be checked against a known answer.
    private func solidJPEG(_ color: UIColor, side: CGFloat = 64) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.jpegData(compressionQuality: 1)!
    }

    private func render(_ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(content: view.frame(width: 320, height: 120))
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    /// Proportion of pixels that are recognisably the avatar's green.
    private func greenShare(_ image: UIImage) throws -> Double {
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hits = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            // Unambiguously green: nothing in the palette (terracotta, cream, ink) is close.
            if g > 140, r < 110, b < 110 { hits += 1 }
        }
        return Double(hits) / Double(width * height)
    }

    private var aChild: ChildResponse {
        ChildResponse(
            id: UUID(), name: "Milo", birthdate: "2022-06-12", pronouns: nil,
            avatarKey: storedKey, familyTimezone: "America/Denver", ageMonths: 50, role: "parent"
        )
    }

    @Test("the avatar is drawn, and the initials disc is not what you get")
    func avatarActuallyDraws() throws {
        let withAvatar = try render(
            ChildHeroCard(child: aChild, avatar: solidJPEG(.green)) {}
        )
        let without = try render(ChildHeroCard(child: aChild, avatar: nil) {})

        let drawn = try greenShare(withAvatar)
        let fallback = try greenShare(without)

        // The disc is 56pt in a 320×120 card — a low single-digit percentage of the area — so the
        // threshold is deliberately loose. The point is that it is present at all.
        #expect(drawn > 0.01, "avatar bytes produced \(drawn) green — the picture never reached the disc")
        #expect(fallback < 0.001, "the no-avatar card should have no green in it, got \(fallback)")
    }

    /// Nil, and bytes that are not an image, must both land on the initials disc rather than on a
    /// blank space or a crash.
    @Test("undecodable bytes fall back to the initials disc")
    func garbageFallsBack() throws {
        let garbage = try render(
            ChildHeroCard(child: aChild, avatar: Data("not an image".utf8)) {}
        )
        let nothing = try render(ChildHeroCard(child: aChild, avatar: nil) {})
        #expect(try greenShare(garbage) < 0.001)
        #expect(garbage.size == nothing.size)
    }
}
#endif

// MARK: - The wire

// MARK: - Replacing

@Suite("Avatar durability — replacing")
@MainActor
struct AvatarReplaceTests {

    @Test("picking a second photo replaces the first everywhere, rather than queueing behind it")
    func replacingOverwritesBothCopies() async throws {
        let child = UUID()
        let store = InMemoryAvatarStore()
        let pending = InMemoryPendingAvatarUploadStore()
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child),
            store: store, pending: pending, transfer: StubAvatarTransfer()
        )

        let first = Data("first-jpeg".utf8)
        let second = Data("second-and-longer-jpeg".utf8)
        sync.enqueue(first, for: child)
        sync.enqueue(second, for: child)

        // Before any sweep: one file, one record, and both describe the second photo.
        #expect(store.load(for: child) == second)
        #expect(pending.all().count == 1)
        #expect(pending.pending(for: child)?.byteCount == second.count)
    }

    @Test("only the surviving photo is uploaded")
    func replacingUploadsOnlyTheNewBytes() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: InMemoryAvatarStore(),
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: transfer
        )

        let second = Data("second-and-longer-jpeg".utf8)
        sync.enqueue(Data("first-jpeg".utf8), for: child)
        sync.enqueue(second, for: child)
        let settled = await sync.sweep()

        #expect(settled == 1)
        // One presign and one commit — not two of each. The first photo never goes up.
        #expect(paths(performer).count == 2)
        #expect(transfer.sent.count == 1)
        #expect(transfer.sent[0].bytes == second)
    }

    /// A parent picking a new photo should not be made to wait out the old one's backoff.
    @Test("replacing starts the retry schedule over")
    func replacingStartsTheBackoffOver() async throws {
        let child = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pending = InMemoryPendingAvatarUploadStore([
            child: PendingAvatarUpload(
                childId: child, contentType: "image/jpeg", byteCount: 10,
                attemptCount: 3, nextAttemptAt: now.addingTimeInterval(3600)
            )
        ])
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child),
            store: InMemoryAvatarStore(), pending: pending, transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("fresh-crop".utf8), for: child)

        let record = try #require(pending.pending(for: child))
        #expect(record.attemptCount == 0)
        #expect(record.nextAttemptAt == nil)
        #expect(record.isRemoval == false)
    }
}

// MARK: - Removing

@Suite("Avatar durability — removing")
@MainActor
struct AvatarRemovalTests {

    /// The mirror of `localWriteHappensFirst`: the picture is gone before anything is attempted,
    /// which is what lets the surface have no upload state and no failure to read.
    @Test("the bytes are gone before anything touches the network")
    func removalIsLocalFirstAndSilent() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        let pending = InMemoryPendingAvatarUploadStore()
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store, pending: pending, transfer: transfer
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        sync.remove(for: child)

        #expect(store.load(for: child) == nil)
        #expect(performer.requests.isEmpty)
        #expect(transfer.sent.isEmpty)
        #expect(pending.pending(for: child)?.isRemoval == true)
    }

    /// One record per child, last intent wins. A photo picked and then removed owes a removal —
    /// never an upload followed by one, which would put the picture in the bucket on the way past.
    @Test("removing replaces an upload that had not gone out yet")
    func removalReplacesAnOutstandingUpload() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: InMemoryAvatarStore(),
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: transfer
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        sync.remove(for: child)
        let settled = await sync.sweep()

        #expect(settled == 1)
        #expect(paths(performer).count == 1)
        #expect(performer.requests.allSatisfy { $0.url?.path().hasSuffix("avatar-upload-url") == false })
        #expect(transfer.sent.isEmpty)
    }

    /// There is no DELETE for an avatar and no storage half at all — a removal is one PATCH.
    @Test("a removal never presigns and never touches storage")
    func removalNeverPresigns() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: InMemoryAvatarStore(),
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: transfer
        )

        sync.remove(for: child)
        await sync.sweep()

        let seen = paths(performer)
        #expect(seen.count == 1)
        #expect(seen[0].hasSuffix(child.uuidString.lowercased()))
        #expect(transfer.sent.isEmpty)
        #expect(transfer.fetched.isEmpty)
    }

    @Test("a landed removal stops being outstanding")
    func removalClearsTheRecord() async throws {
        let child = UUID()
        let pending = InMemoryPendingAvatarUploadStore()
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child),
            store: InMemoryAvatarStore(), pending: pending, transfer: StubAvatarTransfer()
        )

        sync.remove(for: child)
        #expect(pending.pending(for: child) != nil)
        await sync.sweep()
        #expect(pending.pending(for: child) == nil)
    }

    /// **The test this phase most needs, and the one a synthesized encoder passes nothing of.**
    ///
    /// Swift writes optionals with `encodeIfPresent`, which omits nil; the server reads an omitted
    /// key as "no opinion" through `exclude_unset`. The obvious implementation therefore sends
    /// `{}`, gets a 200, and leaves the column exactly where it was.
    @Test("the removal sends an explicit null, and nothing else")
    func theRemovalSendsAnExplicitNull() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: InMemoryAvatarStore(),
            pending: InMemoryPendingAvatarUploadStore(),
            transfer: StubAvatarTransfer()
        )

        sync.remove(for: child)
        await sync.sweep()

        let request = try #require(performer.requests.last)
        #expect(request.httpMethod == "PATCH")
        let body = try #require(request.httpBody)
        // The bytes, first — the one assertion that cannot be satisfied by an omitted key.
        #expect(String(data: body, encoding: .utf8) == #"{"avatar_key":null}"#)

        // Then structurally. Decoded outside the macro: `#expect` rejects throwing calls.
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded.keys.contains("avatar_key"))
        #expect(decoded["avatar_key"] is NSNull)
        // As load-bearing as the null: a removal must not rewrite name, birthdate or timezone.
        #expect(decoded.count == 1)
    }

    @Test("a removal the server refused is retried, and the bytes stay gone")
    func aFailedRemovalIsRetriedAndTheBytesStayGone() async throws {
        let child = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryAvatarStore()
        let pending = InMemoryPendingAvatarUploadStore()
        let sync = AvatarSync(
            api: wiredAPI(StubPerformer(), childId: child, patchStatus: 500),
            store: store, pending: pending, transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        sync.remove(for: child)
        #expect(await sync.sweep(now: now) == 0)

        let record = try #require(pending.pending(for: child))
        #expect(record.isRemoval)
        #expect(record.attemptCount == 1)
        #expect(try #require(record.nextAttemptAt) > now)
        // A failed removal does not put the picture back.
        #expect(store.load(for: child) == nil)
    }

    @Test("a refused removal stops retrying, and still does not restore the picture")
    func aRefusedRemovalStopsRetrying() async throws {
        let child = UUID()
        let performer = StubPerformer()
        performer.on("/v1/children/") { _ in
            (refusedJSON("not_authorized", field: "child_id"), 403)
        }
        let store = InMemoryAvatarStore()
        let pending = InMemoryPendingAvatarUploadStore()
        let sync = AvatarSync(
            api: APIClient(
                baseURL: URL(string: "http://localhost:8000/")!,
                performer: performer,
                tokens: InMemoryTokenStore(TokenPair(accessToken: "a", refreshToken: "r"))
            ),
            store: store, pending: pending, transfer: StubAvatarTransfer()
        )

        sync.enqueue(Data("jpeg".utf8), for: child)
        sync.remove(for: child)
        #expect(await sync.sweep() == 0)

        #expect(pending.pending(for: child) == nil, "a refusal parks the record rather than looping")
        #expect(store.load(for: child) == nil)
    }

    /// **The resurrection bug, and it is the second one this phase is most likely to ship.**
    ///
    /// The local file is gone but `children.avatar_key` is still live until the sweep lands, so a
    /// cache miss would presign a GET, get a 200 and a working URL, and hand back the picture the
    /// parent just removed — then cache it to disk on the way out.
    @Test("a removal that has not been sent yet is not re-downloaded")
    func aPendingRemovalIsNotRedownloaded() async throws {
        let child = UUID()
        let performer = StubPerformer()
        let store = InMemoryAvatarStore()
        let transfer = StubAvatarTransfer()
        let sync = AvatarSync(
            api: wiredAPI(performer, childId: child),
            store: store,
            pending: InMemoryPendingAvatarUploadStore([child: .removal(for: child)]),
            transfer: transfer
        )

        let result = await sync.avatarData(for: child, remoteKey: storedKey)

        #expect(result == nil)
        #expect(performer.requests.isEmpty)
        #expect(transfer.fetched.isEmpty)
        #expect(store.load(for: child) == nil, "nothing may be written back to disk either")
    }
}

// MARK: - The record's shape across an upgrade

@Suite("Avatar durability — a record written before removals existed")
struct PendingAvatarUploadUpgradeTests {

    private func freshDefaults() throws -> UserDefaults {
        let suite = "avatar.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    /// `PendingAvatarUpload` exactly as it was before phase 115 — no `intent`, and nothing else
    /// different. Encoding through this is how the payload gets a genuinely *missing* key rather
    /// than a null one: a fixture sending `"intent":null` would pass against a non-optional
    /// property too, and a missing key is the failure being guarded.
    ///
    /// Written out rather than hand-rolled as JSON text because the stored shape is not the
    /// obvious one: `JSONEncoder` cannot use a `UUID` as an object key, so `[UUID: T]` encodes as
    /// a **flat array** — `[key, value, key, value]` — and a hand-written object fails to decode
    /// for a reason that has nothing to do with what is under test.
    private struct LegacyPendingAvatarUpload: Codable {
        let childId: UUID
        let contentType: String
        let byteCount: Int
        var attemptCount: Int = 0
        var nextAttemptAt: Date?
    }

    private func legacyPayload(for child: UUID) throws -> Data {
        try JSONEncoder().encode([
            child: LegacyPendingAvatarUpload(
                childId: child, contentType: "image/jpeg", byteCount: 41234
            )
        ])
    }

    @Test("a pre-removal record decodes, and means upload")
    func anOldRecordDecodesAsAnUpload() throws {
        let child = UUID()

        let decoded = try JSONDecoder().decode(
            [UUID: PendingAvatarUpload].self, from: try legacyPayload(for: child)
        )

        #expect(decoded.count == 1)
        let record = try #require(decoded[child])
        #expect(record.intent == nil)
        #expect(record.isRemoval == false)
        #expect(record.byteCount == 41234)
    }

    /// The consequence if the above ever regresses: `all()` swallows a decode failure into `[:]`,
    /// so every outstanding avatar on every upgrading phone would be discarded silently.
    @Test("the store does not discard old records on upgrade")
    func theStoreKeepsOldRecordsOnUpgrade() throws {
        let child = UUID()
        let defaults = try freshDefaults()
        defaults.set(
            try legacyPayload(for: child),
            forKey: UserDefaultsPendingAvatarUploadStore.defaultKey
        )

        let store = UserDefaultsPendingAvatarUploadStore(defaults: defaults)
        #expect(store.all().count == 1)
        #expect(store.pending(for: child)?.isRemoval == false)
    }

    @Test("a removal survives a relaunch")
    func aRemovalSurvivesARelaunch() throws {
        let defaults = try freshDefaults()
        let child = UUID()
        let record = PendingAvatarUpload.removal(for: child)

        UserDefaultsPendingAvatarUploadStore(defaults: defaults).save(record)
        // A different instance over the same defaults — i.e. the next launch.
        let reloaded = try #require(
            UserDefaultsPendingAvatarUploadStore(defaults: defaults).pending(for: child)
        )

        #expect(reloaded == record)
        #expect(reloaded.isRemoval)
        #expect(reloaded.intent == .remove)
    }

    @Test("two children can owe different things at once")
    func twoChildrenCanOweDifferentThings() throws {
        let store = UserDefaultsPendingAvatarUploadStore(defaults: try freshDefaults())
        let uploader = UUID(), remover = UUID()

        store.save(PendingAvatarUpload(childId: uploader, contentType: "image/jpeg", byteCount: 9))
        store.save(.removal(for: remover))

        #expect(store.all().count == 2)
        #expect(store.pending(for: uploader)?.isRemoval == false)
        #expect(store.pending(for: remover)?.isRemoval == true)

        store.clear(for: uploader)
        #expect(store.pending(for: remover)?.isRemoval == true, "clearing one must not touch the other's intent")
    }
}

@Suite("Avatar durability — the wire")
struct AvatarWireTests {

    /// The server has always sent this and the client used to drop it.
    @Test("GET /children carries avatar_key onto ChildResponse")
    func childResponseDecodesAvatarKey() throws {
        let json = Data(#"""
        {"id":"9e41dc78-094d-44e5-9b8a-8c5e848173a0","name":"Preflight Kid",
         "birthdate":"2021-04-02","pronouns":null,
         "avatar_key":"children/9e41dc78/avatar/fbf628db.jpg",
         "family_timezone":"America/Denver","role":"parent","age_months":64}
        """#.utf8)

        let child = try APIClient.decoder.decode(ChildResponse.self, from: json)
        #expect(child.avatarKey == "children/9e41dc78/avatar/fbf628db.jpg")
    }

    /// A child with no avatar decodes to nil rather than failing.
    @Test("a null avatar_key decodes as no avatar")
    func nullAvatarKeyDecodes() throws {
        let json = Data(#"""
        {"id":"9e41dc78-094d-44e5-9b8a-8c5e848173a0","name":"Preflight Kid",
         "birthdate":"2021-04-02","pronouns":null,"avatar_key":null,
         "family_timezone":"America/Denver","role":"parent","age_months":64}
        """#.utf8)

        #expect(try APIClient.decoder.decode(ChildResponse.self, from: json).avatarKey == nil)
    }

    @Test("the presign response decodes the three fields the route actually returns")
    func presignResponseDecodes() throws {
        let ticket = try APIClient.decoder.decode(AvatarUploadTicket.self, from: presignJSON())
        #expect(ticket.uploadUrl == storagePutURL)
        #expect(ticket.avatarKey == storedKey)
        #expect(ticket.expiresIn == 3600)
    }

    /// The field is `url`, not `avatar_url` — `docs/blocked.md` never named it.
    @Test("the read response decodes url and expiry")
    func readResponseDecodes() throws {
        let ticket = try APIClient.decoder.decode(AvatarReadTicket.self, from: readTicketJSON())
        #expect(ticket.url == storageGetURL)
        #expect(ticket.expiresIn == 3600)
    }
}
