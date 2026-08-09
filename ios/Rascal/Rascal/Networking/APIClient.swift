import Foundation

/// Anything that can perform a request. Lets tests drive the client without a network.
nonisolated protocol HTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionPerformer: HTTPPerforming {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Not an HTTP response")
        }
        return (data, http)
    }
}

nonisolated enum HTTPMethod: String {
    case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
}

/// Plain JSON over HTTP. No client-specific serialization anywhere — the wire format is the
/// same one a browser will consume, per rule 6 of the project's standing rules.
actor APIClient {
    private let baseURL: URL
    private let performer: HTTPPerforming
    private let tokens: TokenStoring

    /// The in-flight refresh, if one is running. This single property is what makes refresh
    /// single-flight: concurrent 401s await the same task rather than each starting their own.
    private var refreshTask: Task<TokenPair, Error>?

    /// Test seam. Every refresh increments this, so a test can assert exactly one happened.
    private(set) var refreshCount = 0

    init(baseURL: URL, performer: HTTPPerforming = URLSessionPerformer(), tokens: TokenStoring) {
        self.baseURL = baseURL
        self.performer = performer
        self.tokens = tokens
    }

    /// Reads `API_BASE_URL` from Info.plist, which Config.xcconfig supplies. A missing or
    /// malformed value is a build misconfiguration, and failing loudly at launch beats every
    /// request failing later in a way that reads like a server fault.
    static func fromBundle(tokens: TokenStoring, performer: HTTPPerforming = URLSessionPerformer()) -> APIClient {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              url.host() != nil
        else {
            preconditionFailure(
                """
                API_BASE_URL is missing or has no host. Check ios/Rascal/Config.xcconfig — \
                `//` starts a comment in xcconfig, so a URL written inline truncates to the \
                scheme. The scheme must carry its slashes via $(): `http:$()/$()/`.
                """
            )
        }
        return APIClient(baseURL: url, performer: performer, tokens: tokens)
    }

    // MARK: Coding

    /// ISO 8601 with fractional seconds — `2026-08-14T18:22:00.481Z`. The server emits them,
    /// and the plain `.iso8601` strategy rejects the fraction.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601Formatters.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Not an ISO 8601 timestamp: \(raw)"
                )
            }
            return date
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601Formatters.string(from: date))
        }
        return e
    }()

    // MARK: Requests

    @discardableResult
    func send<Response: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        body: (some Encodable)? = Optional<Never>.none,
        headers: [String: String] = [:],
        authenticated: Bool = true,
        as _: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await sendRaw(method, path, body: body, headers: headers, authenticated: authenticated)
        if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("\(Response.self): \(error)")
        }
    }

    func sendRaw(
        _ method: HTTPMethod,
        _ path: String,
        body: (some Encodable)? = Optional<Never>.none,
        headers: [String: String] = [:],
        authenticated: Bool = true
    ) async throws -> Data {
        let request = try buildRequest(method, path, body: body, headers: headers, authenticated: authenticated)

        do {
            return try await execute(request)
        } catch let error as APIError where isAuthChallenge(error) && authenticated {
            // Access tokens live 15 minutes, so this is ordinary use rather than an edge case.
            let refreshed = try await refreshSession()
            var retry = request
            retry.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            // Exactly one retry. A second failure is a real sign-out, not a loop.
            do {
                return try await execute(retry)
            } catch let retryError as APIError where isAuthChallenge(retryError) {
                tokens.clear()
                throw APIError.sessionExpired
            }
        }
    }

    private func isAuthChallenge(_ error: APIError) -> Bool {
        guard case .api(let code, _, _, let status) = error else { return false }
        // A reused refresh token is terminal — the whole chain is revoked server-side, and
        // presenting anything again just confirms it.
        if code == .refreshTokenReused { return false }
        return status == 401 && (code == .unauthenticated || code == .tokenExpired)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await performer.perform(request)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            if let envelope = try? Self.decoder.decode(APIErrorEnvelope.self, from: data) {
                throw APIError.api(
                    code: envelope.error.code,
                    message: envelope.error.message,
                    field: envelope.error.field,
                    status: response.statusCode
                )
            }
            throw APIError.unexpectedStatus(response.statusCode)
        }
        return data
    }

    /// A request carrying the current access token, for the one caller that must stream its own
    /// response instead of buffering it.
    ///
    /// The archive export is tens or hundreds of megabytes and has to land on disk with real
    /// progress; `send` would hold all of it in memory to hand back a `Data`. This is the seam
    /// for that, and it is deliberately narrow — token handling stays here rather than being
    /// reimplemented by the caller. Pair it with `refreshSession()` for the 401 retry, which is
    /// the same single-flight refresh every other request uses.
    func authorizedRequest(_ method: HTTPMethod, _ path: String) throws -> URLRequest {
        try buildRequest(method, path, body: Optional<Never>.none, headers: [:], authenticated: true)
    }

    private func buildRequest(
        _ method: HTTPMethod,
        _ path: String,
        body: (some Encodable)?,
        headers: [String: String],
        authenticated: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.transport("Bad path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        if authenticated, let access = tokens.load()?.accessToken {
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: Refresh — single-flight

    /// The first caller starts the refresh; everyone else awaits the same task and reuses its
    /// result. Two concurrent 401s must not both rotate, because rotation revokes the presented
    /// token — the second refresh would present a token the first had already killed, take
    /// `refresh_token_reused`, and revoke the entire chain. That is a forced logout caused
    /// purely by concurrency.
    func refreshSession() async throws -> TokenPair {
        // Deliberately two steps. Claiming the slot happens in a *synchronous* actor method,
        // which has no suspension points and therefore cannot interleave; only the awaiting
        // is `async`.
        //
        // Doing both in one `async` function looks atomic and is not. Actors are reentrant:
        // they guarantee exclusivity only *between* suspension points, and an `async` function
        // may suspend anywhere the compiler chooses — including between statements that
        // contain no visible `await`. Instrumenting the previous version showed exactly that:
        //
        //     A:sawNil -> A:afterLoad -> B:sawNil -> B:afterLoad -> A:assigned
        //
        // Both callers cleared the `refreshTask == nil` check before either stored a task, so
        // both rotated — and the second rotation presents a refresh token the first already
        // revoked, taking `refresh_token_reused` and revoking the whole chain. A forced logout
        // caused purely by concurrency.
        //
        // Worth knowing: an isolated model of this same shape does *not* reproduce it. The
        // interleaving depends on the surrounding call path, which is why "it reads as atomic"
        // is not evidence of anything. A synchronous claim is safe by construction rather than
        // by inspection.
        let (task, isOwner) = try claimRefreshTask()
        defer {
            // Only the caller that created the task clears it. Callers that adopted an
            // in-flight one must not, or they would wipe a slot they never owned. Task is a
            // struct, so identity has to be tracked rather than compared.
            if isOwner { refreshTask = nil }
        }
        return try await task.value
    }

    /// Synchronous on purpose. See `refreshSession`.
    private func claimRefreshTask() throws -> (task: Task<TokenPair, Error>, isOwner: Bool) {
        if let existing = refreshTask {
            return (existing, false)
        }

        guard let current = tokens.load() else {
            throw APIError.sessionExpired
        }

        let task = Task<TokenPair, Error> { [performer, baseURL, tokens] in
            var request = URLRequest(url: URL(string: "v1/auth/refresh", relativeTo: baseURL)!)
            request.httpMethod = HTTPMethod.post.rawValue
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try Self.encoder.encode(RefreshRequest(refreshToken: current.refreshToken))

            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await performer.perform(request)
            } catch {
                throw APIError.transport(error.localizedDescription)
            }

            guard (200..<300).contains(response.statusCode) else {
                tokens.clear()
                if let envelope = try? Self.decoder.decode(APIErrorEnvelope.self, from: data) {
                    throw APIError.api(
                        code: envelope.error.code,
                        message: envelope.error.message,
                        field: envelope.error.field,
                        status: response.statusCode
                    )
                }
                throw APIError.sessionExpired
            }

            let pair = try Self.decoder.decode(TokenPairResponse.self, from: data)
            // Both halves. Keeping the old refresh token here is the bug that logs the parent
            // out on the next 401.
            let stored = TokenPair(accessToken: pair.accessToken, refreshToken: pair.refreshToken)
            tokens.save(stored)
            return stored
        }

        refreshTask = task
        refreshCount += 1
        return (task, true)
    }

    // MARK: Session

    /// Development login. Mounted only when the API runs with `ENVIRONMENT=local`; it is a
    /// 404 in production, so nothing that ships may depend on it.
    @discardableResult
    func devLogin(email: String, displayName: String) async throws -> SessionResponse {
        let session: SessionResponse = try await send(
            .post, "v1/auth/dev-login",
            body: DevLoginRequest(email: email, displayName: displayName),
            authenticated: false
        )
        tokens.save(TokenPair(accessToken: session.accessToken, refreshToken: session.refreshToken))
        return session
    }

    func hasSession() -> Bool { tokens.load() != nil }

    func signOut() { tokens.clear() }

    /// Revoke the refresh token server-side, then forget both halves.
    ///
    /// Best effort on the network half, and deliberately so. A token this device has thrown
    /// away is already useless to it, and refusing to sign out because the server was
    /// unreachable would strand someone inside an account they asked to leave. The revocation
    /// is what makes the *stolen-phone* case safe, and it is retried by nothing — there is
    /// nothing left to retry with once the token is gone.
    func logout() async {
        if let pair = tokens.load() {
            _ = try? await send(
                .post, "v1/auth/logout",
                body: LogoutRequest(refreshToken: pair.refreshToken),
                authenticated: false,
                as: EmptyResponse.self
            )
        }
        tokens.clear()
    }
}

// MARK: - Wire models

nonisolated struct EmptyResponse: Decodable {}

nonisolated struct DevLoginRequest: Encodable {
    let email: String
    let displayName: String
}

nonisolated struct RefreshRequest: Encodable {
    let refreshToken: String
}

nonisolated struct LogoutRequest: Encodable {
    let refreshToken: String
}

nonisolated struct TokenPairResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
}

nonisolated struct SessionResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
    let user: UserResponse
}

/// `Codable` rather than `Decodable`: the record is persisted between launches so Settings can
/// name the account on a cold, offline start, and `GET /me` corrects it once there is a network.
nonisolated struct UserResponse: Codable, Identifiable, Equatable {
    let id: UUID
    let email: String?
    let displayName: String?
    let isAdmin: Bool
    let createdAt: Date
}

/// Timestamps arrive with fractional seconds and occasionally without. Both parse.
nonisolated enum ISO8601Formatters {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        withFraction.date(from: raw) ?? plain.date(from: raw)
    }

    static func string(from date: Date) -> String {
        withFraction.string(from: date)
    }
}
