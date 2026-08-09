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
    /// The parent signed out deliberately. Distinct from `failed` on purpose: nothing went
    /// wrong, so the screen must not say anything did, and nothing signs back in on its own.
    case signedOut
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
    /// Who is signed in, when this launch is the one that signed them in.
    ///
    /// Nil after a warm start: the token is in the keychain but the user record came back with
    /// the sign-in response and there is no `GET /me` to ask again. Settings falls back to the
    /// configured account rather than showing a blank line.
    private(set) var user: UserResponse?
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
            let session = try await api.devLogin(email: AppConfig.devLoginEmail, displayName: "Dev Parent")
            user = session.user
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

    /// A deliberate sign-out. Revokes the refresh token, forgets the pair, and stops —
    /// **nothing signs back in on its own.** A Sign out button that lands you back on Today two
    /// frames later has not signed you out, it has lied to you.
    func signOut() async {
        await api.logout()
        user = nil
        phase = .signedOut
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
    /// **One container per process, reachable without the app having run.**
    ///
    /// A background upload delegate can fire after a cold launch into a process where SwiftUI
    /// has restored nothing. If it had to wait for the app to hand it a container, the callback
    /// would land nowhere and an upload would finish without ever being marked. Two containers
    /// over one store file is the other way to get that wrong, so there is exactly one and both
    /// the app and the delegate take it from here.
    static let shared: ModelContainer = container()

    static let schema = Schema([Entry.self, Media.self, MediaPart.self])

    /// Open the store, and if it cannot be opened, recover rather than die.
    ///
    /// This used to `fatalError`, on the reasoning that a container that cannot open means
    /// unsynced work would be silently dropped and failing loudly is more honest. That was
    /// wrong, and a device proved it: a property added without a declaration default broke
    /// lightweight migration, and the app crashed on **every launch** with no way back in. The
    /// local work was equally unreachable either way — the crash simply added the app being
    /// permanently unusable on top of it.
    ///
    /// So: try the store, and on failure move it aside and start clean. Deliberately **moved,
    /// not deleted** — whatever was in there is the only copy of anything unsynced, and a file
    /// sitting in `Application Support` can still be recovered by hand or by a later migration.
    /// Deleting it to make the app launch would be choosing convenience over someone's archive.
    static func container() -> ModelContainer {
        do {
            return try ModelContainer(for: schema)
        } catch {
            let quarantined = quarantineStore(reason: error)
            do {
                let recovered = try ModelContainer(for: schema)
                RecoveryLog.record(.init(error: error, movedTo: quarantined))
                return recovered
            } catch {
                // A fresh store that also will not open is not a data problem, it is a broken
                // schema — something no user action can fix and no recovery should paper over.
                fatalError("SwiftData could not open even a new store: \(error)")
            }
        }
    }

    /// Move the existing store files aside. SQLite keeps `-wal` and `-shm` alongside the main
    /// file; leaving either behind makes the "fresh" store inherit the same corruption.
    private static func quarantineStore(reason: Error) -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = support.appending(path: "default.store")
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = support.appending(path: "unreadable-store-\(stamp)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for suffix in ["", "-wal", "-shm"] {
            let from = support.appending(path: "default.store\(suffix)")
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.moveItem(at: from, to: folder.appending(path: "default.store\(suffix)"))
        }
        return folder
    }
}

/// What happened during a store recovery, so the app can say so rather than pretending the
/// device simply had no local data.
enum RecoveryLog {
    struct Event {
        let error: Error
        let movedTo: URL?
    }

    private(set) nonisolated(unsafe) static var last: Event?

    static func record(_ event: Event) {
        last = event
    }
}

