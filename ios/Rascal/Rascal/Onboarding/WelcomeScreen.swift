import AuthenticationServices
import SwiftUI

/// The first thing anybody sees. Wordmark, the promise, and one way in.
///
/// The gradient wash appears here and on no other onboarding step. `Palette` reserves it for
/// emotional beats and names onboarding as one; using it on all six screens would make it the
/// background for ordinary content, which is the thing the reservation exists to prevent.
struct WelcomeScreen: View {
    @Bindable var session: OnboardingSession

    /// Apple's own failure, as opposed to the exchange's. Kept separate from `session.notice`
    /// because nothing has reached the server yet.
    @State private var authorizationNotice: String?

    /// Nil when the build has no `GOOGLE_CLIENT_ID`, which hides the button rather than
    /// offering one that fails at the browser. Read once — it cannot change at runtime.
    private let google = GoogleOAuthConfig()

    var body: some View {
        ZStack {
            Gradients.wash
                .opacity(0.55)
                .ignoresSafeArea()
                // Decorative. It carries no information and VoiceOver should walk straight past.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Text("DOGEAR")
                    .typeRole(.label)
                    .tracking(2.6)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)

                Text("Let's save today before it's gone.")
                    .typeRole(.display)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)

                Text("One small thing a day about your kid. It takes a minute and it lasts forever.")
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                signIn
                    .padding(.top, 34)
            }
            .padding(.horizontal, OnboardingLayout.margin)
            .padding(.bottom, 44)
        }
    }

    @ViewBuilder
    private var signIn: some View {
        VStack(spacing: 12) {
            // Held payload: the exchange carrying a name Apple will never send again failed, so
            // the only correct recovery is to send *that* payload again. Re-prompting Apple here
            // would return `fullName: nil` and lose the name for good, which is why this is a
            // retry button rather than another sign-in button.
            if session.pendingExchange != nil {
                OnboardingNotice(message: session.notice ?? "That didn't reach the server.") {
                    Task { await session.retryExchange() }
                }
                .padding(.bottom, 4)
            }

            SignInWithAppleButton(.signIn) { request in
                // **Every time, not just the first.** The client cannot know which authorization
                // is the first one for this Apple ID, and asking for a scope you did not request
                // is not possible after the fact.
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(session.isWorking)

            // **Secondary, and visually second — a rule rather than a layout choice.**
            // `ios/CLAUDE.md` records it: Apple stays primary. It is also hidden entirely when
            // the build carries no client id, because a button that cannot work is worse than
            // no button, and this app shipped without one for a while.
            if let google {
                OnboardingSecondaryButton(title: "Continue with Google") {
                    Task { await session.signInWithGoogle(using: GoogleSignInFlow(config: google)) }
                }
                .disabled(session.isWorking)
            }

            if session.pendingExchange == nil, let notice = session.notice ?? authorizationNotice {
                OnboardingNotice(message: notice)
            }

            Text("Your archive is tied to your Apple ID. There's nothing else to set up.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            #if DEBUG
            devLogin
            #endif
        }
    }

    /// The local fixture account. **Debug builds only.**
    ///
    /// **Kept, and kept reachable — in a debug build.** Sign in with Apple needs an Apple
    /// Developer Program enrollment that has not cleared yet, so without this there is no way to
    /// open the app at all on a simulator.
    ///
    /// It used to compile into Release as well, on the reasoning that `POST /auth/dev-login` is
    /// registered only when the API runs with `ENVIRONMENT=local` and is a 404 anywhere else, so
    /// tapping it could only fail. That is a shipped binary whose safety is a variable set on a
    /// server: one staging rollback with the wrong environment and every installed copy has a
    /// one-tap way into a shared fixture account. It is also a button offering "the development
    /// account" to a parent, which is not a thing the product does. So it is gated the way
    /// `TodayScreen.debugResetBoard` already is, and `AppSession.signIn`,
    /// `OnboardingSession.signInWithDevLogin`, `APIClient.devLogin` and the `DEV_*` keys in the
    /// Release `Info.plist` went with it.
    #if DEBUG
    @ViewBuilder
    private var devLogin: some View {
        OnboardingSecondaryButton(title: "Use the development account") {
            Task { await session.signInWithDevLogin() }
        }
        .disabled(session.isWorking)
        .padding(.top, 2)
    }
    #endif

    private func handle(_ result: Result<ASAuthorization, Error>) {
        authorizationNotice = nil
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let input = AppleCredentialInput(credential)
            else {
                authorizationNotice = "Apple didn't send a usable credential. Try again."
                return
            }
            Task { await session.signIn(with: input) }

        case .failure(let error):
            // Cancelling is a decision, not a failure. Saying anything about it would be the app
            // arguing with someone who just said no.
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            authorizationNotice = "Apple couldn't complete that sign-in. Try again."
        }
    }
}
