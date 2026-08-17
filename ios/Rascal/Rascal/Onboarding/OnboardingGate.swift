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

    /// Every child this account can see, in the order `GET /children` returned them.
    ///
    /// Held so the switcher has something to list and so `canSwitchChild` can be answered without
    /// a request. Empty until the first resolve, and empty is not "no children" — it is "not
    /// asked yet", which is why `state` and not this is what decides between setup and Today.
    private(set) var children: [ChildResponse] = []

    /// **The chevron condition, and the reason it lives here rather than in the view.**
    ///
    /// `ChildSwitcherPill` states the rule it exists to serve: *one child and a chevron is a
    /// control that lies*. This is the only place that knows how many children there are, so this
    /// is where the rule is expressed — the pill stays a dumb view that draws a chevron when it
    /// is handed a closure, and the closure is nil until there is somewhere to go.
    var canSwitchChild: Bool { children.count > 1 }

    /// The child on screen, when there is one. Nil in every other state, which is what the
    /// switcher's checkmark wants — during setup or a sign-out there is no current child to tick.
    var readyChild: ChildResponse? {
        if case .ready(let child) = state { return child }
        return nil
    }

    /// What the parent has typed. Persisted after every step.
    var draft: OnboardingDraft

    /// The processed avatar, held until the child exists and can own it. Optional throughout —
    /// a skipped avatar is a complete onboarding.
    var avatar: Data?

    /// The session owner the rest of the app already uses. Handed to `RootView` unchanged.
    let account: AppSession

    /// Permission, the preference, and the token. Owned here because the last onboarding step
    /// needs it and Settings needs the same instance — two would disagree about whether the
    /// single re-offer had been spent.
    let notifications: NotificationPreference

    private let drafts: OnboardingDraftStoring
    private let appleIDs: AppleUserIDStoring
    private let credentials: AppleCredentialChecking

    /// Which child the parent was last looking at, across launches. See `SelectedChildStoring`
    /// for why nothing downstream has to trust what comes out of it.
    private let selected: SelectedChildStoring

    /// Saves the crop locally **and** owes it to the server. Setup is the only place in the app
    /// that produces an avatar, so this is the only place that enqueues one.
    private let avatarSync: AvatarSync
    /// Signing out has to reach the Home Screen too. The widget's snapshot holds a child's first
    /// name and today's prompts, and it outlives the session unless something removes it — a
    /// signed-out phone with the child's name still on its Lock Screen is the visible version of
    /// that bug.
    private let widget: WidgetSnapshotPublisher

    /// The rest of what a signed-out phone was keeping: the SwiftData cache, the staged files and
    /// their thumbnails, the avatar, and the share inbox. **Only `signOut()` reaches this** — see
    /// `LocalArchiveErasing` for why the other two ways a session ends must not.
    private let localArchive: LocalArchiveErasing

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
        selected: SelectedChildStoring = UserDefaultsSelectedChildStore(),
        avatars: AvatarStoring = LocalAvatarStore(),
        pendingAvatars: PendingAvatarUploadStoring = UserDefaultsPendingAvatarUploadStore(),
        widget: WidgetSnapshotPublisher = .live,
        // **The one default here that is not the live implementation**, and deliberately so: this
        // erases a child's data at rest, and a test that constructs a session and signs out must
        // not take the process's real store and Application Support with it. `live()` supplies
        // the real one. See `LocalArchiveErasing`.
        //
        // Spelled `nil` rather than `NoLocalArchiveErasure()` because a default argument is
        // evaluated in a nonisolated context, and the eraser is `@MainActor`. The inert one is
        // built in the body instead, which is main-actor isolated like the rest of this type.
        localArchive: LocalArchiveErasing? = nil,
        notifications: NotificationPreference? = nil
    ) {
        self.account = account
        self.drafts = drafts
        self.appleIDs = appleIDs
        self.credentials = credentials
        self.selected = selected
        self.localArchive = localArchive ?? NoLocalArchiveErasure()
        // Built here rather than injected whole so the two stores stay separately substitutable —
        // a test asserting where the bytes landed passes `avatars`, and one asserting what is
        // still owed passes `pendingAvatars`.
        self.avatarSync = AvatarSync(api: account.api, store: avatars, pending: pendingAvatars)
        self.widget = widget
        self.draft = drafts.load() ?? OnboardingDraft()
        self.notifications = notifications ?? NotificationPreference(
            authorizer: NotificationAuthorizerFactory.live(),
            backend: PushRegistrar(api: account.api, authorizer: NotificationAuthorizerFactory.live())
        )
    }

    static func live() -> OnboardingSession {
        let account = AppSession.live()
        let registrar = PushRegistrar(
            api: account.api,
            authorizer: NotificationAuthorizerFactory.live()
        )
        let session = OnboardingSession(
            account: account,
            // The real eraser, wired here and nowhere else. `init` cannot default to it — see the
            // note on the parameter.
            localArchive: LocalArchiveErasure(),
            notifications: NotificationPreference(
                authorizer: NotificationAuthorizerFactory.live(),
                backend: registrar
            )
        )
        // The delegate's only route back into the app. Done here rather than in `init` so a test
        // building a session never reaches for the process-wide instance.
        PushCenter.shared.attach(registrar)
        return session
    }

    // MARK: Resuming

    /// Resolve whatever this launch already has.
    func resume() async {
        state = .loading
        notice = nil
        resolveFailed = false

        guard await account.api.hasSession() else {
            // **The third way a session ends, and the one that clears nothing on its way out.**
            // `APIClient` drops the token pair itself when a refresh is rejected — a revoked
            // device, an expired refresh token — without going through either sign-out path. This
            // launch is the first moment anything notices, and if it only set the state, a phone
            // that is now signed out would keep the child's first name and the day's prompts on
            // its Lock Screen indefinitely.
            widget.publish(nil)
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
            self.children = children
            // The remembered child if the account still has it, and otherwise the first — which
            // is what every account had before there was anything to remember. A stored id that
            // names a child this account can no longer see is not an error to report: the child
            // may have been removed on another device, and landing on the first one is the same
            // answer a fresh install gives.
            if let child = children.first(where: { $0.id == selected.load() }) ?? children.first {
                finish(with: child)
                // Re-read the account, exactly as `AppSession.start()` used to before the gate
                // took over resolving. Deliberately best effort and deliberately after the state
                // is set: the archive does not depend on knowing the parent's name, and failing
                // a launch over it would trade something that matters for something that does
                // not. Offline, the stored copy stands.
                if let fetched = try? await account.api.me() {
                    account.apply(user: fetched)
                    // The server owns `notify_enabled` and `notify_local_time`. Seeding the
                    // mirror here means Settings renders the real preference on a cold launch
                    // rather than the type's default, which would read as "off" for a parent who
                    // had turned it on.
                    notifications.apply(user: fetched)
                }
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
            notifications.apply(user: session.user)
            await resolveChild()
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Sign in with Google.
    ///
    /// **Secondary to Apple by design, and separate from `exchange` on purpose.** There is no
    /// held-payload retry here, because the thing that made one necessary for Apple does not
    /// exist: Apple sends `fullName` exactly once per Apple ID ever, so a failed exchange loses
    /// it forever and the only correct recovery is to resend the identical bytes. Google returns
    /// its claims on every token, so a failure here is recovered by simply signing in again —
    /// and a retry button that re-prompted Apple would have been the bug, not the feature.
    ///
    /// Cancelling is silent. Someone who closed the sheet said no, and the app does not argue.
    func signInWithGoogle(using flow: GoogleSignInFlow) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        do {
            let exchange = try await flow.run()
            let session = try await account.api.signInWithGoogle(exchange)
            account.apply(user: session.user)
            notifications.apply(user: session.user)
            await resolveChild()
        } catch GoogleSignInError.cancelled {
            return
        } catch let error as GoogleSignInError {
            notice = Self.explainGoogle(error)
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Plain sentences, no blame, and never the raw error. Each one says what to do next.
    private static func explainGoogle(_ error: GoogleSignInError) -> String {
        switch error {
        case .cancelled:
            ""
        case .notConfigured:
            "Google sign-in isn't set up in this build."
        case .stateMismatch:
            // Genuinely suspicious rather than merely broken, so it does not invite a retry loop.
            "That sign-in didn't come back the way it went out. Try again."
        case .noAuthorizationCode, .noIdentityToken:
            "Google didn't send back what we needed. Try again."
        case .transport:
            "Couldn't reach Google just now. Try again in a moment."
        }
    }

    /// Finish a magic-link sign-in.
    ///
    /// **Reached with or without a session, and both are ordinary.** A parent signing in on a
    /// new phone has none. A parent who just added the address from Settings has one, and this
    /// is the click that verifies it — the server treats verifying a new address and signing in
    /// with an old one as the same act, because both are proof of reading the inbox.
    ///
    /// A spent or expired link is a plain sentence saying to ask for another, never an error
    /// screen: the link expiring after fifteen minutes is the design working.
    func completeEmailSignIn(token: String) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        // Captured before the exchange, because the exchange replaces the stored token pair.
        let signedInAs = account.user?.id

        do {
            let session = try await account.api.completeEmailSignIn(token: token)

            // **A magic link must never silently move an active session to another account.**
            //
            // Without this check the app has a login-CSRF hole with an unusually bad payoff:
            // anyone who mails a parent a link to *their* account swaps the parent's session,
            // and every entry written afterwards — photographs, a letter to their child —
            // lands in the attacker's archive, with nothing on screen suggesting anything
            // changed. It is a data-exfiltration bug wearing a sign-in bug's clothes.
            //
            // Verifying an address added from Settings is the legitimate same-account case and
            // is unaffected. A *different* account signs out rather than swapping: the link's
            // token is already spent, and leaving somebody signed in to an archive that is not
            // theirs is the one outcome worth refusing outright.
            if let signedInAs, signedInAs != session.user.id {
                await signOut()
                notice = "That sign-in link was for a different account, so you've been "
                    + "signed out. Sign in again to get back to your archive."
                return
            }

            account.apply(user: session.user)
            notifications.apply(user: session.user)
            await resolveChild()
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Local development login. **Debug builds only.**
    ///
    /// Reachable from the welcome screen because Sign in with Apple needs an Apple Developer
    /// Program enrollment that has not cleared, and this is how the app is worked on until it
    /// does. The route is `404` unless the API runs with `ENVIRONMENT=local` — which used to be
    /// the whole guard, and is a guard living on a server rather than in the binary. It is
    /// compiled out of Release now, together with `WelcomeScreen.devLogin`, `APIClient.devLogin`
    /// and `AppConfig`, so nothing that ships can depend on it because nothing that ships has it.
    #if DEBUG
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
            notifications.apply(user: session.user)
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
    #endif

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
                familyTimezone: draft.timezone,
                // Nil when the parent skipped the question, and a skip is a finished setup.
                // Sent on the create rather than PATCHed a moment later: the answer is already
                // in hand, and asking on one screen to write it from another is a second round
                // trip for nothing.
                pronouns: draft.pronouns
            )
            finish(with: child)
        } catch {
            // **A refusal is not a lost response.** The server rejects a bad birthdate or a blank
            // name before it writes anything, so there is no row to adopt — and consulting the
            // guard anyway would replace the message telling the parent what to fix with a child
            // that came from somewhere else entirely.
            let refused = (error as? APIError)?.code == .validationFailed
            if !refused, let existing = try? await account.api.children().first {
                finish(with: existing)
                return
            }
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: The notification step

    /// "Turn it on". **The only path in the app that reaches the system permission prompt.**
    ///
    /// Setup completes afterwards either way — granted, denied, or a preference write that
    /// failed. A permission outcome is never allowed to be the reason a parent cannot finish
    /// naming their kid.
    func acceptNotifications(at time: NotifyTime) async {
        await notifications.acceptSoftAsk(time: time)
        await finishSetup()
    }

    /// "Not now". **Fires nothing.** The system prompt is untouched, so the offer can be made
    /// once more after the first entry and still mean something.
    func declineNotifications() async {
        notifications.declineSoftAsk()
        await finishSetup()
    }

    /// The end of setup, whichever way the last step was answered.
    func finishSetup() async {
        await createChild()
    }

    /// Onboarding is over. The draft goes, because the server's copy is now the truth and a
    /// stale local one could only contradict it.
    private func finish(with child: ChildResponse) {
        if let avatar {
            // Saves locally first, then records what the server is owed. Neither step touches the
            // network, so setup finishes at the same speed it always did.
            avatarSync.enqueue(avatar, for: child.id)
            self.avatar = nil
            // One prompt first attempt, detached so a slow upload cannot hold the parent on the
            // last screen of setup. **Not a retry loop** — if this fails, the record stays and the
            // next foreground sweep picks it up, which is the mechanism rather than a spinner.
            Task { [avatarSync] in await avatarSync.sweep() }
        }
        drafts.clear()
        notice = nil
        resolveFailed = false
        // Remembered here rather than only in `select(_:)`, so the child a parent just created —
        // and the one resolved on a launch that fell back to the first — is the one the next
        // launch opens. Without this, creating a second child would still reopen the first.
        selected.save(child.id)
        state = .ready(child)
    }

    // MARK: Switching child

    /// Show a different child.
    ///
    /// **This is a state change on the gate and nothing else, and that is the whole design.**
    /// `RootView` is rendered with `.id(child.id)`, so a new `.ready` tears the entire subtree
    /// down and builds it again — which is what makes every child-bound object in the app correct
    /// across a switch. `TodayModel`, `SyncEngine`, `ShareDrain`, `TimelineModel`, `MomentsModel`
    /// and the Timeline's `@Query` predicates all capture their child once, at init, and none of
    /// them re-read it. Mutating a `childId` in place anywhere below this line would leave every
    /// one of them pointed at the previous child while the header showed the new one: the
    /// timeline would list a sibling's entries, and the sync engine would advance the wrong
    /// child's cursor. That is not a display bug, it is a corrupted archive.
    ///
    /// **Nothing local is erased.** Both children's rows live in one store and neither is
    /// entitled to empty it — `LocalArchiveErasing` belongs to sign-out alone. The rows are
    /// already tagged with their own `childId`, so the switch is a change of which ones are read.
    func select(_ child: ChildResponse) {
        // Selecting the child already showing must not tear the tree down: it would drop the
        // board, restart sync and clear the widget to arrive back where it started.
        guard case .ready(let current) = state, current.id != child.id else { return }
        // The snapshot holds one child's first name and today's prompts, and the extension does
        // no work of its own. Left alone, the Home Screen keeps the previous child's name until
        // the new board lands — and forever if that fetch fails. Clearing is the honest state:
        // `WidgetSnapshotSync` republishes as soon as Today answers.
        widget.publish(nil)
        selected.save(child.id)
        notice = nil
        state = .ready(child)
    }

    /// Add a second — or fifth — child, from a signed-in session.
    ///
    /// **Not the setup flow, and deliberately not `.needsChild`.** That state means "authenticated,
    /// zero children" and drives the whole six-step flow, the last step of which asks for
    /// notification permission. A parent adding a sibling has already answered that question for
    /// the account, and `ios/CLAUDE.md` puts re-prompting out of scope by any mechanism. So this
    /// is a create against the same route, from a sheet that collects the four things the route
    /// requires and nothing else — avatar and everything else stay editable in Settings, where
    /// they already are for the child that exists.
    ///
    /// **The new child is switched to on success.** Creating somebody and being left looking at
    /// their sibling is the kind of thing that reads as a failure, and the switch is the same
    /// gate-level state change every other switch is.
    ///
    /// Returns whether it landed, so the sheet knows whether to close. The notice is set here
    /// either way, because this type owns the interface's voice for everything on this path.
    @discardableResult
    func addChild(
        name: String,
        birthdate: String,
        familyTimezone: String,
        pronouns: PronounSet?
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        do {
            let child = try await account.api.createChild(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                birthdate: birthdate,
                familyTimezone: familyTimezone,
                pronouns: pronouns
            )
            // Appended before the switch, because `select` is a no-op for a child the session
            // does not know about — and because `canSwitchChild` reads this list, so the pill
            // gains its chevron in the same turn the second child arrives.
            children.append(child)
            select(child)
            return true
        } catch {
            // **No adopt-the-existing-child fallback here, unlike `createChild`.** That guard
            // exists because setup has no `Idempotency-Key` and a lost response would otherwise
            // strand a parent who already has a child on the server. It cannot be reused: this
            // account already has children, so "find one and adopt it" would silently select a
            // sibling and report success for a create that may never have happened. A parent who
            // sees the error and taps again gets a duplicate they can see and we can talk about,
            // which is the better failure.
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
            return false
        }
    }

    /// Forget the last thing that went wrong. Used when opening a sheet that would otherwise
    /// inherit a notice from an attempt the parent has already walked away from.
    func clearNotice() { notice = nil }

    /// Re-read the account's children, so a child added on another device appears in the list.
    ///
    /// Best effort and deliberately silent: this runs when the switcher opens, and a parent who
    /// is offline should still be able to switch between the children this device already knows
    /// about. Failure leaves the previous list standing rather than emptying it.
    func refreshChildren() async {
        guard let fetched = try? await account.api.children(), !fetched.isEmpty else { return }
        children = fetched
    }

    // MARK: Signing out

    /// A deliberate sign-out, from Settings or from the way out of setup.
    ///
    /// Everything about the account goes: the refresh token is revoked server-side, the stored
    /// user record and Apple subject are forgotten, a half-finished setup draft goes with them,
    /// and — the part that used to be missing — so does the child's data at rest. Leaving a
    /// child's name in UserDefaults after someone asked to leave is the sort of thing "signed
    /// out" is supposed to mean, and so is leaving a thumbnail of every photo in their timeline.
    ///
    /// **This is the only path in the app that erases anything.** A revoked Apple credential and
    /// a rejected refresh both end the session too, and both leave every byte where it is; see
    /// `LocalArchiveErasing`.
    func signOut() async {
        // **Before `account.signOut()`, and the order is the point.** `DELETE /v1/devices/{token}`
        // authenticates with the session it is revoking against, so revoking after the tokens are
        // cleared is a request that 401s and a phone that keeps receiving the child's missions
        // after someone asked to be signed out.
        await notifications.revokeDevice()
        await account.signOut()
        forgetLocalIdentity()
        state = .signedOut
        // **After the state change, and with no `await` between them.** Setting `.signedOut` is
        // what takes `RootView` off screen; running these two statements in one turn means SwiftUI
        // never renders a timeline over a store that is being emptied underneath it. Anything
        // asynchronous here would reintroduce exactly that frame.
        localArchive.erase()
    }

    private func forgetLocalIdentity() {
        appleIDs.clear()
        drafts.clear()
        // Which child was on screen is part of what a signed-out phone must stop remembering, and
        // it goes with the list itself — leaving `children` populated would let `canSwitchChild`
        // answer true for an account that is no longer signed in.
        selected.clear()
        children = []
        draft = OnboardingDraft()
        avatar = nil
        pendingExchange = nil
        notice = nil
        resolveFailed = false
        widget.publish(nil)
    }

    /// Drop the session without revoking anything, for a credential Apple has already invalidated.
    ///
    /// **Both of the two ways out carry the widget with them**, and they are genuinely separate
    /// paths: this one runs when Apple reports a revoked credential or the API answers 401, and
    /// `forgetLocalIdentity` runs when the parent taps Sign out. Clearing in only one of them
    /// leaves the other with a Home Screen the app no longer has an account for.
    private func forgetSession() async {
        await account.api.signOut()
        appleIDs.clear()
        // The same reasoning as `forgetLocalIdentity`, and for the same reason both paths already
        // clear the widget: a revoked credential ends the session just as completely as a tapped
        // Sign out, and a remembered child that outlives it would be restored for whoever signs
        // in next on this phone.
        selected.clear()
        children = []
        widget.publish(nil)
    }
}

// MARK: - The gate

struct OnboardingGate: View {
    @State private var session = OnboardingSession.live()
    @Environment(\.scenePhase) private var scenePhase
    /// The spinner is deliberately late. See `.task`.
    @State private var showsLoadingChrome = false
    /// A widget tap, held until there is something that can act on it.
    ///
    /// **The gate catches the URL because the gate is the only view that is always there.** iOS
    /// delivers a launch URL as the scene connects, which on a cold launch is while this is still
    /// `.loading` and `RootView` does not exist — an `onOpenURL` attached down there never runs,
    /// and the tap does nothing. Since a widget is mostly tapped when the app is *not* already
    /// running, that was the normal path, not the edge one.
    @State private var pendingLink: WidgetDeepLink?
    /// An invitation waiting to be dealt with. **Held across sign-in**, which is the whole
    /// reason it lives on the gate rather than inside the screen: the person tapping the link
    /// is usually signed out, and a token that lived inside a sheet would be gone the moment
    /// they went to the welcome screen to get a session.
    @State private var pendingInvite: InviteLink?
    /// Set while they are away signing in, so the invitation is not re-presented over the
    /// welcome screen it just handed them to.
    @State private var inviteDeferred = false

    /// **Presented from the gate, not from Today.** The sheet's selection replaces the whole
    /// `RootView` subtree, so a sheet owned by a view inside that subtree would be destroying its
    /// own presenter as it acted.
    @State private var isPresentingSwitcher = false

    /// **Presented here for the same reason the switcher is.** A successful add ends in a switch,
    /// which replaces the whole `RootView` subtree — including the Settings screen the parent
    /// tapped from. A sheet owned down there would be tearing down its own presenter.
    @State private var isPresentingAddChild = false

    /// Nil while they are away signing in, so the invitation does not reappear on top of the
    /// welcome screen it just handed them to.
    private var presentedInvite: Binding<InviteLink?> {
        Binding(
            get: { inviteDeferred ? nil : pendingInvite },
            set: { newValue in
                if newValue == nil, !inviteDeferred { pendingInvite = nil }
            }
        )
    }

    @ViewBuilder
    private func inviteScreen(_ invite: InviteLink) -> some View {
        InviteAcceptScreen(
            model: InviteAcceptModel(api: session.account.api, token: invite.token),
            isSignedIn: session.state != .signedOut,
            onSignIn: { inviteDeferred = true },
            onDone: {
                pendingInvite = nil
                inviteDeferred = false
            }
        )
    }

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
                // refresh — and the child it already resolved, so `RootView` does not go and
                // fetch it a second time.
                // Sign-out is handed down as a closure rather than left for the gate to notice.
                // Watching `account.phase` was tried and is wrong: `onChange` fires on a *change*,
                // so a second sign-out in one launch — sign out, sign back in, sign out again —
                // sets a value that is already `.signedOut`, fires nothing, and leaves Today on
                // screen behind a revoked token.
                // The timezone travels with the id because the widget snapshot needs it and
                // `GET /today` does not carry one: the response states the child's local date but
                // not the zone it was computed in, and the widget has to be able to ask whether
                // that date is still today. The gate already holds the whole `ChildResponse`, so
                // this costs a parameter rather than a second request.
                // The birthdate travels for the same reason and at the same cost: the camera-roll
                // backfill says how old the child was in a month with nothing written in it, and
                // `GET /today` carries only `age_months` — an age as of today, which says nothing
                // about a month in 2019. The gate holds the whole `ChildResponse` already.
                // The name and pronouns ride along on the same argument, at the same cost and for
                // the same reason: every prompt body is rendered for this child at the moment it
                // is shown, and the alternative is a second request from four different screens.
                RootView(
                    session: session.account,
                    childId: child.id,
                    familyTimezone: child.familyTimezone,
                    childBirthdate: child.birthdate,
                    promptSubject: child.promptSubject,
                    onSignOut: { await session.signOut() },
                    // Nil with one child, which is what makes the pill a label rather than a
                    // control that lies. The condition is `OnboardingSession.canSwitchChild`
                    // because this is the only layer that knows how many children exist.
                    onSwitchChild: session.canSwitchChild ? { isPresentingSwitcher = true } : nil,
                    // **Never nil.** Unlike the switcher, this is offered with one child — that
                    // is the account it exists for. See `SettingsScreen.childrenSection`.
                    onAddChild: {
                // **Clear first.** `addChild` sets `notice` on failure and only clears it at the
                // top of its own next invocation, so a parent who failed, cancelled, and came
                // back later found the sheet pre-loaded with an error about an action they had
                // not taken yet.
                session.clearNotice()
                isPresentingAddChild = true
            },
                    notifications: session.notifications,
                    pendingLink: $pendingLink
                )
                .id(child.id)
            }
        }
        // Held rather than acted on. A signed-out phone can be tapped through from a widget that
        // has not caught up yet, and the honest response is to show the welcome screen and forget
        // the link — which is what happens, because only `RootView` ever reads this.
        .sheet(isPresented: $isPresentingSwitcher) {
            ChildSwitcherSheet(
                children: session.children,
                selected: session.readyChild?.id,
                onRefresh: { await session.refreshChildren() },
                onSelect: { session.select($0) }
            )
        }
        .sheet(isPresented: $isPresentingAddChild) {
            AddChildSheet(
                familyTimezone: session.readyChild?.familyTimezone,
                notice: session.notice,
                isWorking: session.isWorking
            ) { name, birthdate, timezone, pronouns in
                await session.addChild(
                    name: name,
                    birthdate: birthdate,
                    familyTimezone: timezone,
                    pronouns: pronouns
                )
            }
            // **The only refresh a one-child account can reach.** `refreshChildren` was written
            // so a child added on another device appears in the list, and its only other caller
            // is the switcher sheet — which does not open until there are two children, i.e.
            // never for exactly the account that needs to discover the second one. A parent
            // opening Add a child is the likeliest person to have already added one elsewhere,
            // so asking here closes the loop: if the account has two now, the pill gains its
            // chevron behind this sheet.
            .task { await session.refreshChildren() }
        }
        // Presented over whatever the gate is showing, because an invitation has to work in
        // both session states. `inviteDeferred` is what lets them go and sign in without this
        // reappearing on top of the welcome screen.
        .fullScreenCover(item: presentedInvite) { invite in
            inviteScreen(invite)
        }
        // They went to sign in and now have a session. Bring the invitation back — this is the
        // "you'll come straight back here" the screen promised, and the reason the token is held
        // on the gate rather than in the sheet.
        .onChange(of: session.state) { _, state in
            guard inviteDeferred, state != .signedOut, state != .loading else { return }
            inviteDeferred = false
        }
        .onOpenURL { url in
            // **A magic link is checked first, and it is a different kind of URL.** The widget's
            // is a custom scheme that only ever arrives at an app already signed in; this one is
            // an `https://` universal link whose whole job is to *get* somebody signed in, so it
            // has to be handled even when there is no session — which is exactly the state the
            // widget path assumes it is never in.
            if let link = SignInLink.parse(url) {
                Task { await session.completeEmailSignIn(token: link.token) }
                return
            }
            // **Checked before the widget's custom scheme and after the magic link**, in the
            // order the URLs can actually arrive: a magic link and an invitation are both
            // `https://` universal links that may reach a signed-out app, and the widget's only
            // ever arrives at one already signed in.
            if let invite = InviteLink.parse(url) {
                pendingInvite = invite
                inviteDeferred = false
                return
            }
            pendingLink = WidgetDeepLink.parse(url)
        }
        // A tapped notification arrives through the delegate rather than as a URL, so it lands in
        // `PushCenter` and is drained here into the same held link a widget tap uses. **One
        // pending-link path, not two** — the rule that an unknown assignment lands on Today lives
        // at the other end of it and must not be reimplemented alongside.
        .onChange(of: PushCenter.shared.pendingLink) { _, link in
            guard let link else { return }
            pendingLink = link
            PushCenter.shared.pendingLink = nil
        }
        // Rule 5: a parent who turned notifications on in iOS Settings comes back to an app that
        // registers a token and asks them nothing. Every foreground, because that is the only
        // moment the app can notice.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await session.notifications.refresh() }
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
