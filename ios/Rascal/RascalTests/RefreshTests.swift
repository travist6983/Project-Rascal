import Foundation
import Testing

@testable import Rascal

/// A scripted network. No test touches the real one.
final class StubPerformer: HTTPPerforming, @unchecked Sendable {
    struct Rule {
        let match: @Sendable (URLRequest) -> Bool
        let respond: @Sendable (Int) -> (Data, Int)
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private(set) var requests: [URLRequest] = []
    /// Per-path hit counts, so a test can assert exactly how many times refresh was called.
    private(set) var hits: [String: Int] = [:]
    /// Delay applied to refresh, to hold the window open while a second caller arrives.
    var refreshDelay: Duration = .zero

    func on(_ pathContains: String, respond: @escaping @Sendable (Int) -> (Data, Int)) {
        lock.lock(); defer { lock.unlock() }
        rules.append(Rule(match: { $0.url?.path().contains(pathContains) ?? false }, respond: respond))
    }

    func count(for pathContains: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return hits.filter { $0.key.contains(pathContains) }.values.reduce(0, +)
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path() ?? ""
        if path.contains("refresh"), refreshDelay > .zero {
            try await Task.sleep(for: refreshDelay)
        }

        // Locking is confined to a synchronous helper. Taking a lock directly in an `async`
        // function is what the compiler objects to — nothing here is held across a suspension,
        // but the diagnostic is about shape, not about this particular body being safe.
        let (n, rule) = record(request, path: path)

        guard let rule else { return (Data("{}".utf8), http(request, 200)) }
        let (data, status) = rule.respond(n)
        return (data, http(request, status))
    }

    /// Synchronous by design — see `perform`.
    private func record(_ request: URLRequest, path: String) -> (Int, Rule?) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        hits[path, default: 0] += 1
        return (hits[path] ?? 1, rules.last { $0.match(request) })
    }

    private func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private func unauthorized() -> Data {
    Data(#"{"error":{"code":"token_expired","message":"expired","field":null}}"#.utf8)
}

private func tokenPair(_ suffix: String) -> Data {
    Data(#"{"access_token":"access-\#(suffix)","refresh_token":"refresh-\#(suffix)","token_type":"bearer","expires_in":900}"#.utf8)
}

@Suite("Token refresh")
struct RefreshTests {

    @Test("two concurrent 401s produce exactly one refresh")
    func singleFlightRefresh() async throws {
        let performer = StubPerformer()
        // Hold refresh open long enough that both callers are certainly inside the window.
        performer.refreshDelay = .milliseconds(120)

        // Every protected call 401s until a refresh has happened, then succeeds.
        let refreshed = Mutex(false)
        performer.on("/today") { _ in
            refreshed.value ? (Data(#"{"ok":true}"#.utf8), 200) : (unauthorized(), 401)
        }
        performer.on("/refresh") { _ in
            refreshed.value = true
            return (tokenPair("new"), 200)
        }

        let store = InMemoryTokenStore(TokenPair(accessToken: "old", refreshToken: "refresh-old"))
        let client = APIClient(baseURL: URL(string: "http://localhost:8000/")!, performer: performer, tokens: store)

        // Two protected requests racing, both of which will 401.
        async let a: Data = client.sendRaw(.get, "v1/children/x/today")
        async let b: Data = client.sendRaw(.get, "v1/children/y/today")
        _ = try await (a, b)

        #expect(performer.count(for: "refresh") == 1,
                "a second rotation would present a token the first already revoked")
        // The client-side counter agrees: only one caller ever claimed the refresh slot.
        #expect(await client.refreshCount == 1)

        // Both halves of the new pair were persisted.
        let stored = try #require(store.load())
        #expect(stored.accessToken == "access-new")
        #expect(stored.refreshToken == "refresh-new")
    }

    @Test("the original request is retried once after a successful refresh")
    func retriesOnce() async throws {
        let performer = StubPerformer()
        performer.on("/today") { n in
            n == 1 ? (unauthorized(), 401) : (Data(#"{"ok":true}"#.utf8), 200)
        }
        performer.on("/refresh") { _ in (tokenPair("2"), 200) }

        let store = InMemoryTokenStore(TokenPair(accessToken: "old", refreshToken: "r"))
        let client = APIClient(baseURL: URL(string: "http://localhost:8000/")!, performer: performer, tokens: store)

        _ = try await client.sendRaw(.get, "v1/children/x/today")
        #expect(performer.count(for: "today") == 2, "one original, one retry")
        #expect(performer.count(for: "refresh") == 1)
    }

    @Test("a second 401 after refreshing surfaces as a sign-out, not a loop")
    func doesNotLoop() async throws {
        let performer = StubPerformer()
        performer.on("/today") { _ in (unauthorized(), 401) }
        performer.on("/refresh") { _ in (tokenPair("3"), 200) }

        let store = InMemoryTokenStore(TokenPair(accessToken: "old", refreshToken: "r"))
        let client = APIClient(baseURL: URL(string: "http://localhost:8000/")!, performer: performer, tokens: store)

        await #expect(throws: APIError.sessionExpired) {
            _ = try await client.sendRaw(.get, "v1/children/x/today")
        }
        #expect(performer.count(for: "today") == 2, "exactly one retry, then stop")
        #expect(store.load() == nil, "the store is cleared on a real sign-out")
    }

    @Test("refresh_token_reused is terminal and clears the session")
    func reusedIsTerminal() async throws {
        let performer = StubPerformer()
        performer.on("/today") { _ in (unauthorized(), 401) }
        performer.on("/refresh") { _ in
            (Data(#"{"error":{"code":"refresh_token_reused","message":"reused","field":null}}"#.utf8), 401)
        }

        let store = InMemoryTokenStore(TokenPair(accessToken: "old", refreshToken: "r"))
        let client = APIClient(baseURL: URL(string: "http://localhost:8000/")!, performer: performer, tokens: store)

        let error = await #expect(throws: APIError.self) {
            _ = try await client.sendRaw(.get, "v1/children/x/today")
        }
        #expect(error?.code == .refreshTokenReused)
        #expect(store.load() == nil, "the whole chain is revoked server-side; keeping tokens is a lie")
        #expect(performer.count(for: "refresh") == 1, "a reused token is never retried")
    }
}

/// Minimal lock box, so the stubs can mutate shared state from concurrent callers.
final class Mutex<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
