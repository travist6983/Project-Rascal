import Foundation
import SwiftData
import SwiftUI

/// Configuration the app reads once at launch. Everything here comes from Config.xcconfig via
/// Info.plist — no base URL and no UUID appears in Swift source.
enum AppConfig {
    static var devLoginEmail: String {
        string("DEV_LOGIN_EMAIL") ?? "dev@rascal.local"
    }

    static var devChildId: UUID? {
        string("DEV_CHILD_ID").flatMap(UUID.init(uuidString:))
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

/// Where the app is in its session lifecycle.
enum SessionPhase: Equatable {
    case launching
    case signedIn(childId: UUID)
    /// Sign-in could not complete. Carries what to tell the parent — and what they can do.
    case failed(String)
}

/// Owns the session and the child the app is showing.
///
/// Phase one authenticates with dev-login, which exists only when the API runs with
/// `ENVIRONMENT=local`. Real Sign in with Apple replaces `signIn()` and nothing else — that is
/// the whole point of the credential row.
@MainActor
@Observable
final class AppSession {
    private(set) var phase: SessionPhase = .launching
    let api: APIClient

    private let tokens: TokenStoring

    init(api: APIClient, tokens: TokenStoring) {
        self.api = api
        self.tokens = tokens
    }

    static func live() -> AppSession {
        let tokens = KeychainTokenStore()
        return AppSession(api: APIClient.fromBundle(tokens: tokens), tokens: tokens)
    }

    /// A stored token means we can go straight to Today. If it has expired, the first request
    /// refreshes transparently; if refresh fails, that request surfaces `.sessionExpired` and
    /// the view calls `signOutAndRetry()`.
    func start() async {
        if await api.hasSession(), let child = await resolveChild() {
            phase = .signedIn(childId: child)
            return
        }
        await signIn()
    }

    func signIn() async {
        do {
            _ = try await api.devLogin(email: AppConfig.devLoginEmail, displayName: "Dev Parent")
            guard let child = await resolveChild() else {
                phase = .failed(
                    """
                    Signed in, but this account has no child yet. dev-login creates a user, \
                    never a child. Create one with POST /v1/children, then reopen.
                    """
                )
                return
            }
            phase = .signedIn(childId: child)
        } catch let error as APIError {
            phase = .failed(Self.explain(error))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func signOutAndRetry() async {
        await api.signOut()
        phase = .launching
        await signIn()
    }

    /// Config supplies the child for now, but it is verified against the server rather than
    /// trusted — a stale UUID in an xcconfig would otherwise 404 every request with no clue
    /// why. Falling back to the first child the account can see keeps a fresh checkout working.
    private func resolveChild() async -> UUID? {
        guard let children = try? await api.children(), !children.isEmpty else { return nil }
        if let configured = AppConfig.devChildId, children.contains(where: { $0.id == configured }) {
            return configured
        }
        return children.first?.id
    }

    private static func explain(_ error: APIError) -> String {
        if case .api(_, _, _, let status) = error, status == 404 {
            return """
                dev-login answered 404. The API is not running with ENVIRONMENT=local — \
                it is mounted only in a local build.
                """
        }
        if case .transport = error {
            return """
                Can't reach the API. Check it is running (`make dev`) and that API_HOST in \
                Config.xcconfig points at it.
                """
        }
        return error.userMessage
    }
}

/// The local cache. SwiftData holds entries so a save survives a force quit and an offline
/// launch; the server remains the source of truth for everything it owns.
enum LocalStore {
    static func container() -> ModelContainer {
        let schema = Schema([Entry.self, Media.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            // A container that cannot open means unsynced work would be silently dropped.
            // Failing here is louder and more honest than pretending the cache exists.
            fatalError("SwiftData container failed to open: \(error)")
        }
    }
}
