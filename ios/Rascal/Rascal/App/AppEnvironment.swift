import Foundation
import OSLog
import SwiftData
import SwiftUI

/// The fixture identity the dev-login path signs in as. Read from Config.xcconfig via
/// Info.plist — no UUID appears in Swift source.
///
/// **Debug builds only, along with the rest of the dev-login path.** `DEV_LOGIN_EMAIL` and
/// `DEV_CHILD_ID` are no longer in the Release `Info.plist`, so in a shipped build these would
/// answer with the hardcoded fallback and nothing at all — a fixture address baked into a binary
/// for a route that build can no longer call. Everything this type holds is dev-login's; if a key
/// that is *not* arrives, it comes back out of the gate with that key.
///
/// `API_BASE_URL` is deliberately not here: `APIClient.fromBundle` reads it directly, because the
/// base URL is needed in every configuration and this is not.
#if DEBUG
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
#endif

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
/// Sign in with Apple is the way in. The dev-login resolution this type used to perform on launch
/// is still here, in the `#if DEBUG` section at the bottom, and is reachable from nothing but the
/// welcome screen's debug-only button and `MeTests` — a shipped binary does not contain it.
@MainActor
@Observable
final class AppSession {
    private(set) var phase: SessionPhase = .launching
    /// Who is signed in.
    ///
    /// Populated from the stored record before any request goes out, so a cold or offline launch
    /// names the account immediately, then corrected by `GET /me`. It used to be nil after a warm
    /// start — the record arrived once with the sign-in response and there was no route to ask
    /// again — which is why Settings had to fall back to the configured account.
    private(set) var user: UserResponse?
    let api: APIClient

    private let tokens: TokenStoring
    private let record: UserRecordStoring

    init(api: APIClient, tokens: TokenStoring, record: UserRecordStoring = InMemoryUserRecordStore()) {
        self.api = api
        self.tokens = tokens
        self.record = record
        // Before anything else, so the first render of Settings has a name rather than a blank
        // line it fills in a moment later.
        self.user = record.load()
    }

    static func live() -> AppSession {
        let tokens = KeychainTokenStore()
        return AppSession(
            api: APIClient.fromBundle(tokens: tokens),
            tokens: tokens,
            record: UserDefaultsUserRecordStore()
        )
    }

    /// Fold a user record back in, from either `/me` route, so the name the parent just set is
    /// what every screen shows without waiting for a relaunch — and what the next cold launch
    /// shows before any request goes out.
    func apply(user updated: UserResponse) {
        user = updated
        record.save(updated)
    }

    /// A deliberate sign-out. Revokes the refresh token, forgets the pair, and stops —
    /// **nothing signs back in on its own.** A Sign out button that lands you back on Today two
    /// frames later has not signed you out, it has lied to you.
    ///
    /// The child's data at rest is not this method's to erase: `OnboardingSession.signOut` owns
    /// that, because it is the only caller that knows the parent asked to leave rather than a
    /// credential having expired underneath them. See `LocalArchiveErasing`.
    func signOut() async {
        await api.logout()
        user = nil
        // The stored record goes with the token. Leaving somebody's name in UserDefaults after
        // they asked to leave is the sort of thing "signed out" is supposed to mean.
        record.clear()
        phase = .signedOut
    }

    /// Drop the session without revoking anything, for a credential that is already dead.
    ///
    /// **The user record goes too, and leaving it behind was a live hazard rather than untidiness.**
    /// `AppSession.init` rehydrates `user` from this record on every cold launch
    /// (`self.user = record.load()`), so a session ended involuntarily left a *ghost identity*
    /// behind: the app was signed out, and `account.user?.id` still answered. `completeEmailSignIn`
    /// compares a magic link's account against exactly that value, and until phase 132 a mismatch
    /// ran the erasing sign-out — so a stale record could route a re-authentication into deleting
    /// an archive. Both halves are fixed; this is the half that stops the ghost existing.
    ///
    /// Deliberately **not** `signOut()`: there is nothing to revoke with, and a network call to
    /// hand back a token the server has already rejected would fail and change nothing.
    func forgetSession() async {
        await api.signOut()
        user = nil
        record.clear()
        phase = .signedOut
    }

    // MARK: - The dev-login path — debug builds only

    /// Everything below is the local fixture sign-in, and none of it is in a shipped binary.
    ///
    /// It used to compile into Release, guarded only by the API returning 404 unless it runs with
    /// `ENVIRONMENT=local` — a shipped binary whose safety is a variable set on a server.
    /// `ios/CLAUDE.md` says nothing that ships may depend on this route, and the only way to mean
    /// that is for it not to be there. `WelcomeScreen.devLogin`,
    /// `OnboardingSession.signInWithDevLogin`, `APIClient.devLogin`, `AppConfig` and the `DEV_*`
    /// keys in the Release `Info.plist` are gated together, so the whole path appears and
    /// disappears as one thing.
    #if DEBUG

    /// **No longer the app's launch path. Do not call this from a view.**
    ///
    /// `OnboardingGate` resolves the session now — it checks the Apple credential state, decides
    /// between `signedOut`, `needsChild` and `ready`, and refreshes `/me` once a child is found.
    /// Calling this as well would run a second, competing resolution that re-fetches the child and
    /// falls back to `dev-login` when it cannot, which in production tells the parent "the API is
    /// not running with ENVIRONMENT=local".
    ///
    /// Kept because `MeTests` drives the user-record rules through it and those rules are real.
    /// Retiring it, and `signIn`/`signOutAndRetry` with it, is a cleanup of its own — see
    /// `docs/reports/phase-5-onboarding.md`.
    ///
    /// A stored token means we can go straight to Today. If it has expired, the first request
    /// refreshes transparently; if refresh fails, that request surfaces `.sessionExpired`.
    func start() async {
        if await api.hasSession(), let child = await resolveChild() {
            phase = .signedIn(childId: child)
            await refreshUser()
            return
        }
        await signIn()
    }

    /// Re-read the account on launch.
    ///
    /// Deliberately best effort and deliberately after the phase is set: the archive does not
    /// depend on knowing the parent's name, and blocking the app on this — or failing the launch
    /// because it did not answer — would trade something that matters for something that does
    /// not. Offline, the stored copy stands and is not cleared.
    private func refreshUser() async {
        guard let fetched = try? await api.me() else { return }
        apply(user: fetched)
    }

    func signIn() async {
        do {
            let session = try await api.devLogin(email: AppConfig.devLoginEmail, displayName: "Dev Parent")
            apply(user: session.user)
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
    #endif
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

    /// `Assignment` joined this in the sync-pull phase, so `GET /sync`'s `assignments` array has
    /// somewhere to land. A **new entity** is the one schema change that cannot fail lightweight
    /// migration the way rule 6 of `ios/CLAUDE.md` describes: there are no existing rows of a type
    /// that has never existed, so there is nothing for SwiftData to backfill. `StoreMigration
    /// Tests` proves it against a real file written by the previous three-entity schema.
    static let schema = Schema([Entry.self, Media.self, MediaPart.self, Assignment.self])

    /// Where SwiftData puts the store when no configuration names a URL. Written out rather than
    /// left implicit because `quarantineStore(at:)` has to move that exact file, and a recovery
    /// that moves a *different* path than the one that failed to open is a recovery that does
    /// nothing while reporting success.
    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "default.store")
    }

    /// Open the app's store, and if it cannot be opened, recover rather than die.
    ///
    /// The no-argument overload is the app's, and it opens the container exactly the way it
    /// always has — `ModelContainer(for: schema)`, no configuration, SwiftData's own default
    /// location. `container(at:)` is the same recovery over a named file, which is what lets
    /// `StoreMigrationTests` drive this for real instead of asserting `FileManager` works.
    static func container() -> ModelContainer {
        open(storeURL: defaultStoreURL) { try ModelContainer(for: schema) }
    }

    /// The same open-and-recover, against a store file named outright.
    static func container(at storeURL: URL) -> ModelContainer {
        open(storeURL: storeURL) {
            try ModelContainer(for: schema, configurations: ModelConfiguration(url: storeURL))
        }
    }

    /// Try the store, and on failure move it aside and start clean.
    ///
    /// This used to `fatalError`, on the reasoning that a container that cannot open means
    /// unsynced work would be silently dropped and failing loudly is more honest. That was
    /// wrong, and a device proved it: a property added without a declaration default broke
    /// lightweight migration, and the app crashed on **every launch** with no way back in. The
    /// local work was equally unreachable either way — the crash simply added the app being
    /// permanently unusable on top of it.
    ///
    /// The move is deliberately **a move, not a delete** — whatever was in there is the only copy
    /// of anything unsynced, and a file sitting in `Application Support` can still be recovered by
    /// hand or by a later migration. Deleting it to make the app launch would be choosing
    /// convenience over someone's archive.
    private static func open(
        storeURL: URL,
        _ makeContainer: () throws -> ModelContainer
    ) -> ModelContainer {
        do {
            return try makeContainer()
        } catch {
            let quarantined = quarantineStore(at: storeURL)
            do {
                let recovered = try makeContainer()
                RecoveryLog.record(.init(error: error, movedTo: quarantined))
                return recovered
            } catch {
                // A fresh store that also will not open is not a data problem, it is a broken
                // schema — something no user action can fix and no recovery should paper over.
                fatalError("SwiftData could not open even a new store: \(error)")
            }
        }
    }

    /// Move the store files aside and return the folder they went to, or nil if there was no
    /// store there. SQLite keeps `-wal` and `-shm` alongside the main file; leaving either behind
    /// makes the "fresh" store inherit the same corruption.
    ///
    /// **Not private, and that is the point.** It was, and the test that claimed to hold the
    /// move-not-delete line could not reach it — so it wrote a file to a temp directory, read the
    /// same bytes back, and would have passed unchanged the day this became `removeItem`. This is
    /// the one function in the app that stands between a failed migration and somebody's only
    /// copy of an unsynced entry, so it is reachable and it is tested.
    static func quarantineStore(at storeURL: URL) -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: storeURL.path) else { return nil }

        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = directory.appending(path: "unreadable-store-\(stamp)", directoryHint: .isDirectory)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

        for suffix in ["", "-wal", "-shm"] {
            let from = directory.appending(path: "\(name)\(suffix)")
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.moveItem(at: from, to: folder.appending(path: "\(name)\(suffix)"))
        }
        return folder
    }

    /// Empty the cache without disturbing the container every live `ModelContext` is reading.
    ///
    /// Batch deletes through `mainContext` rather than destroying and rebuilding the container:
    /// `shared` is a `static let` handed to `RascalApp`, `Uploader` and `MediaCoordinator`, and
    /// replacing the file underneath them would leave three readers pointing at a store that no
    /// longer exists. Called on a deliberate sign-out and from nowhere else — see
    /// `LocalArchiveErasing`.
    @MainActor
    static func eraseContents() throws {
        let context = shared.mainContext
        try context.delete(model: Entry.self)
        try context.delete(model: Media.self)
        try context.delete(model: MediaPart.self)
        try context.delete(model: Assignment.self)
        try context.save()
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

// MARK: - Signing out for real

/// Erasing the child's data at rest.
///
/// **A seam, and it exists so this is impossible to run by accident.** Sign-out cleared the token,
/// the stored user record, the Apple subject, the draft and the widget snapshot — and left every
/// thing that actually holds a childhood: entry bodies, notes, transcripts and tags in the
/// SwiftData store, the permanent thumbnail cache of every photo in the timeline, the child's
/// avatar crop in a directory that is explicitly *included* in iCloud backup, and whatever the
/// share extension had staged. A phone that is signed out, handed on and restored to a new owner
/// carried all of it.
///
/// Three ways a session can end, and only one of them may do this:
///
/// - the parent taps Sign out — `OnboardingSession.signOut`, deliberate, **erases**;
/// - Apple reports a revoked credential — `OnboardingSession.forgetSession`, not a decision the
///   parent made here, erases nothing;
/// - a refresh is rejected and `APIClient` drops the pair itself — noticed at the next `resume()`,
///   also not a decision, erases nothing.
///
/// The last two are why this is a protocol rather than a function anybody can call: an accidental
/// call from an error path destroys an archive, and there is no undo.
@MainActor
protocol LocalArchiveErasing {
    func erase()
}

/// The real one. Handed to `OnboardingSession` by `OnboardingSession.live()` and by nothing else.
@MainActor
struct LocalArchiveErasure: LocalArchiveErasing {
    private static let log = Logger(subsystem: "app.rascal", category: "signout")

    /// **Synchronous, and it has to be.** The caller sets `state = .signedOut` and then calls this
    /// with no suspension point in between, so SwiftUI never gets a render pass while the rows are
    /// going: by the time it draws, `RootView` is gone. An `await` here would put a live timeline
    /// on screen over a store being emptied under it, reading model objects that no longer exist.
    ///
    /// Ordered bulkiest-and-most-sensitive first, and every step independent — a failure in one
    /// does not stop the rest, because a partial erase is strictly better than none.
    func erase() {
        let manager = FileManager.default

        // The App Group inbox: staged records, the photos they name, and the owner marker. Its
        // own API, because a record this build cannot decode is invisible to a loop over
        // `pending()` and still names files sitting in `media/`.
        ShareInbox.shared.clear()

        // Staged originals and the thumbnail cache. The originals are copies of photos the
        // library still holds — `StagingStore` exists because the picker's temporary may vanish,
        // not because this is the only copy — and the thumbnails are a 400px render of every
        // photo in the timeline, which is the single largest picture of a child left behind here.
        //
        // The stores are constructed rather than having their paths re-derived here: each one owns
        // where it puts things, and a second copy of that path in this file is a second thing to
        // get wrong. Both recreate their directory the next time something is written.
        try? manager.removeItem(at: StagingStore().root)

        // The avatar crop. Uploaded to `children.avatar_key` and re-downloaded on demand, so
        // removing it costs one presigned GET the next time this account signs in — and it is the
        // one file here that is deliberately *included* in iCloud backup.
        try? manager.removeItem(at: LocalAvatarStore().root)

        // **And what this phone still owed the server about that avatar**, which used to be safe
        // to leave and is not any more. An orphaned *upload* record is harmless — the sweep finds
        // no bytes and drops it — but a *removal* record carries an instruction rather than a
        // payload, and it survives a sign-out. Left here it would issue a `PATCH` clearing
        // `avatar_key` on a child the next account signed in on this phone does not own. The
        // server refuses it, so the blast radius is bounded; a write aimed at somebody else's row
        // is still not a thing to ship deliberately.
        UserDefaults.standard.removeObject(forKey: UserDefaultsPendingAvatarUploadStore.defaultKey)

        // **The sync cursors, which used to survive this.** Emptying the store and keeping the
        // position is the combination that silently never refills: sign back in as the same
        // account and `/sync` resumes from a timestamp describing an archive that was just
        // deleted, so it returns the handful of rows changed since and nothing else. Latent only
        // because `pullEnabled` ships false, and a bad thing to discover on the day it is not.
        UserDefaultsSyncStateStore().forgetAllChildren()

        // Any export zip left in Caches. Already best-effort and already called when the Settings
        // screen appears; called again here because "left the tab mid-download" and "signed out"
        // are the same orphan.
        ArchiveExport.purgeStale()

        // Last, because a row pointing at a file that is gone is a state the app already handles,
        // and a file with no row pointing at it is one nothing ever collects.
        do {
            try LocalStore.eraseContents()
        } catch {
            // Nothing to offer the parent: they have already left the screen this was started
            // from, and there is no action that would help. Logged so a device sync report can
            // say why an old entry came back.
            Self.log.error("sign-out could not empty the local store: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// **The default, and inert on purpose.**
///
/// Every other store `OnboardingSession` takes defaults to the live implementation, and this one
/// must not: `OnboardingSessionTests` calls `signOut()` directly, and a live eraser there would
/// open the process's real on-disk `LocalStore.shared` and empty the simulator's Application
/// Support out from under `MediaCoordinatorTests`, which shares it. So the app wires the eraser in
/// `OnboardingSession.live()` — the same place, and for the same reason, that `PushCenter.shared`
/// is attached there rather than in `init`.
@MainActor
struct NoLocalArchiveErasure: LocalArchiveErasing {
    func erase() {}
}

