import SwiftUI

/// What the app shows before it shows the archive.
///
/// The gate sits above `RootView` and decides one thing: whether this launch has a session and a
/// child. It owns the `AppSession` and hands the same instance down, so there is exactly one
/// `APIClient` and exactly one single-flight refresh in the process — two would race a rotating
/// refresh token against itself and force a logout.

// MARK: - State

/// Where the app is before Today.
///
/// Four cases and no failure case, on purpose. A failure here is never a *place* the app is in —
/// it is something that just happened at the step the parent is already standing on, and the
/// recovery is always "try that again" rather than "go somewhere else". So failures are carried
/// as `notice` and `resolveFailed` alongside the state, which is what lets a lost connection
/// leave every typed character exactly where it was.
enum SessionState: Equatable {
    /// Resolving a persisted session. Also the state during a resolve that failed — see
    /// `OnboardingSession.resolveFailed`, because "we could not find out" is honestly still
    /// loading rather than signed out.
    case loading
    case signedOut
    /// Authenticated, zero children. True for the whole of setup: the child is created once, at
    /// the end, so this never briefly means "one child, still on the avatar screen".
    case needsChild
    case ready(ChildResponse)
}

// MARK: - The machine

@MainActor
@Observable
final class OnboardingSession {
    private(set) var state: SessionState = .loading
    /// The last thing that went wrong, in the interface's voice. Nil until something does.
    private(set) var notice: String?
    /// A resolve that could not complete for a reason that is not "signed out" — almost always
    /// no connection. Kept apart from `notice` because it is the one failure that needs its own
    /// full-screen retry rather than a line under a button.
    private(set) var resolveFailed = false
    /// A request is in flight. Disables the button that started it, so a double tap cannot send
    /// the same create twice.
    private(set) var isWorking = false

    /// What the parent has typed. Persisted after every step.
    var draft: OnboardingDraft

    /// The processed avatar, held until the child exists and can own it. Optional throughout —
    /// a skipped avatar is a complete onboarding.
    var avatar: Data?

    /// The session owner the rest of the app already uses. Handed to `RootView` unchanged.
    let account: AppSession

    private let drafts: OnboardingDraftStoring
    private let appleIDs: AppleUserIDStoring
    private let credentials: AppleCredentialChecking
    private let avatars: AvatarStoring

    /// **The one payload in the app that cannot be recreated.**
    ///
    /// Apple returns `fullName` on the first authorization for an Apple ID and never again. If
    /// the exchange carrying it fails, re-prompting Apple gets a credential with `fullName: nil`
    /// and the name is gone permanently — so the failed attempt is held here and retried
    /// verbatim. In memory only, and cleared on success: a lost name is acceptable, a parent's
    /// name written to disk to survive a process death is not.
    private(set) var pendingExchange: AppleExchange?

    init(
        account: AppSession,
        drafts: OnboardingDraftStoring = UserDefaultsOnboardingDraftStore(),
        appleIDs: AppleUserIDStoring = UserDefaultsAppleUserIDStore(),
        credentials: AppleCredentialChecking = LiveAppleCredentialCheck(),
        avatars: AvatarStoring = LocalAvatarStore()
    ) {
        self.account = account
        self.drafts = drafts
        self.appleIDs = appleIDs
        self.credentials = credentials
        self.avatars = avatars
        self.draft = drafts.load() ?? OnboardingDraft()
    }

    static func live() -> OnboardingSession {
        OnboardingSession(account: .live())
    }

    // MARK: Resuming

    /// Resolve whatever this launch already has.
    func resume() async {
        state = .loading
        notice = nil
        resolveFailed = false

        guard await account.api.hasSession() else {
            state = .signedOut
            return
        }

        // Revoked in Settings → Apple ID → Sign in with Apple. The parent expects to be signed
        // out, and the tokens we hold would keep working until they expired, so this is the only
        // moment the app can honour that. Nothing local is destroyed beyond the session itself.
        if let userID = appleIDs.load() {
            switch await credentials.state(forUserID: userID) {
            case .revoked, .notFound:
                await forgetSession()
                state = .signedOut
                return
            case .authorized, .unknown:
                break
            }
        }

        await resolveChild()
    }

    /// `GET /children` decides between `needsChild` and `ready`.
    private func resolveChild() async {
        do {
            let children = try await account.api.children()
            // Multi-kid is out of scope: take the first and build no picker.
            if let child = children.first {
                finish(with: child)
            } else {
                draft = drafts.load() ?? OnboardingDraft()
                state = .needsChild
            }
        } catch let error as APIError where isSignedOut(error) {
            await forgetSession()
            state = .signedOut
        } catch let error as APIError {
            // A token we hold and a server we cannot reach is *not* a signed-out parent. Staying
            // in `loading` with a retry keeps the session rather than dumping someone onto a
            // sign-in screen they have no connection to complete.
            notice = error.userMessage
            resolveFailed = true
            state = .loading
        } catch {
            notice = error.localizedDescription
            resolveFailed = true
            state = .loading
        }
    }

    private func isSignedOut(_ error: APIError) -> Bool {
        error == .sessionExpired || error.code == .unauthenticated || error.code == .tokenExpired
    }

    // MARK: Signing in

    /// Exchange a fresh Apple credential.
    func signIn(with credential: AppleCredentialInput) async {
        // Saved before the exchange: `getCredentialState` needs it on the next launch whether or
        // not this attempt succeeds, and it is an opaque subject rather than anything private.
        appleIDs.save(credential.userID)
        await exchange(AppleExchange(credential))
    }

    /// Retry the exchange that failed, byte for byte.
    ///
    /// Deliberately not "ask Apple again". A second authorization returns `fullName: nil`, so
    /// re-prompting is precisely how the name is lost.
    func retryExchange() async {
        guard let pendingExchange else { return }
        await exchange(pendingExchange)
    }

    private func exchange(_ payload: AppleExchange) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        // Held before the call and cleared only on success, so a throw anywhere below leaves it
        // intact for `retryExchange`.
        pendingExchange = payload
        defer { isWorking = false }

        do {
            let session = try await account.api.signInWithApple(payload)
            pendingExchange = nil
            // **The server's user object is the source of truth for the display name.** Apple's
            // `fullName` is never cached or rendered — it went out in the request and that is the
            // last this client sees of it.
            account.apply(user: session.user)
            await resolveChild()
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Local development login. Reachable from the welcome screen because Sign in with Apple
    /// needs an Apple Developer Program enrollment that has not cleared, and this is how the app
    /// is worked on until it does. The route is `404` unless the API runs with
    /// `ENVIRONMENT=local`, so nothing that ships can depend on it.
    func signInWithDevLogin() async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        do {
            let session = try await account.api.devLogin(
                email: AppConfig.devLoginEmail,
                displayName: "Dev Parent"
            )
            account.apply(user: session.user)
            await resolveChild()
        } catch let error as APIError {
            notice = Self.explainDevLogin(error)
        } catch {
            notice = error.localizedDescription
        }
    }

    private static func explainDevLogin(_ error: APIError) -> String {
        if case .api(_, _, _, let status) = error, status == 404 {
            return """
                dev-login answered 404. The API is not running with ENVIRONMENT=local — \
                it is mounted only in a local build.
                """
        }
        return error.userMessage
    }

    // MARK: Steps

    func advance() {
        guard let next = draft.step.next else { return }
        draft.step = next
        persist()
    }

    func goBack() {
        guard let previous = draft.step.previous else { return }
        notice = nil
        draft.step = previous
        persist()
    }

    /// Every keystroke and every wheel turn. Cheap, and it is what makes a kill mid-setup
    /// resume with the input intact.
    func persist() {
        drafts.save(draft)
    }

    // MARK: Creating the child

    /// The last thing onboarding does. Called from the avatar step, whether the parent added one
    /// or skipped it.
    ///
    /// **The duplicate-child guard lives here.** `POST /children` has no `Idempotency-Key`, so a
    /// create whose *response* was lost in transit has still created a child, and a blind retry
    /// would produce a second one that the product has no way to show or remove. Asking
    /// `GET /children` before surfacing a retry closes it: if a child is there, the create
    /// worked and only the answer went missing.
    func createChild() async {
        guard !isWorking else { return }
        guard draft.isNameValid, let birthdate = draft.birthdate else {
            notice = "Add a name and a birthdate first."
            return
        }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        do {
            let child = try await account.api.createChild(
                name: draft.trimmedName,
                birthdate: birthdate,
                familyTimezone: draft.timezone
            )
            finish(with: child)
        } catch {
            if let existing = try? await account.api.children().first {
                finish(with: existing)
                return
            }
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    /// Onboarding is over. The draft goes, because the server's copy is now the truth and a
    /// stale local one could only contradict it.
    private func finish(with child: ChildResponse) {
        if let avatar {
            avatars.save(avatar, for: child.id)
            self.avatar = nil
        }
        drafts.clear()
        notice = nil
        resolveFailed = false
        state = .ready(child)
    }

    // MARK: Signing out

    private func forgetSession() async {
        await account.api.signOut()
        appleIDs.clear()
    }
}

// MARK: - The gate

struct OnboardingGate: View {
    @State private var session = OnboardingSession.live()
    /// The spinner is deliberately late. See `.task`.
    @State private var showsLoadingChrome = false

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            switch session.state {
            case .loading:
                if session.resolveFailed {
                    ResolveFailedView(message: session.notice) {
                        Task { await session.resume() }
                    }
                } else if showsLoadingChrome {
                    LaunchIndicator()
                }
                // Under ~150ms: nothing at all. The parent sees the launch canvas, then Today.

            case .signedOut:
                WelcomeScreen(session: session)

            case .needsChild:
                ChildSetupFlow(session: session)

            case .ready(let child):
                // The same `AppSession` instance, so the whole app shares one client and one
                // refresh. `RootView` resolves the child again on its own `.task`; that is one
                // extra `GET /children` at the handoff and it keeps `RootView` unchanged.
                RootView(session: session.account)
                    .id(child.id)
            }
        }
        .task {
            // A warm launch resolves a stored session in well under 150ms. A spinner that
            // appears and disappears inside two frames reads as a glitch, not as progress — so
            // the indicator is scheduled rather than shown, and cancelled if the answer beats it.
            let chrome = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                showsLoadingChrome = true
            }
            await session.resume()
            chrome.cancel()
        }
    }
}

// MARK: - Loading and failure

private struct LaunchIndicator: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.terracotta)
            Text("Opening the archive")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A launch that could not reach the server. The session is intact and nothing has been lost,
/// and the copy says so rather than implying a sign-out.
private struct ResolveFailedView: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.inkMuted)
                .accessibilityHidden(true)
            Text("Can't reach the archive")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text(message ?? "No connection. Everything here is still here.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Layout.screenMargin * 2)
    }
}
