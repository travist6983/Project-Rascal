import Foundation

/// Joining a household from a tapped link.
///
/// **Every failure gets its own sentence.** A generic error here is a dead end for somebody who
/// has just been handed a link by their spouse and has no idea what the app is — they cannot
/// retry their way out of an expired invitation, and telling them "something went wrong" leaves
/// them asking the other parent to debug it.
///
/// The server answers a **single `404`** for unknown, expired, revoked and already-spent tokens,
/// deliberately: telling them apart would say whether a token ever existed. So the client cannot
/// distinguish those four either, and does not pretend to — one honest sentence covers them, and
/// it is the sentence that says what to do next.
@MainActor
@Observable
final class InviteAcceptModel {

    nonisolated enum State: Equatable {
        case loading
        /// The link is real. `canAccept` is false when nobody is signed in yet.
        case preview(InvitePreview, canAccept: Bool)
        /// Unknown, expired, revoked, or already used — the server does not say which.
        case noLongerValid
        /// Accepted. `children` is what they can now reach.
        case joined(childCount: Int)
        /// Reachable but refused for a reason worth its own words.
        case refused(String)
        /// The network, not the invitation. The only state with a retry, because it is the only
        /// one where the identical request could plausibly succeed.
        case unreachable(String)
    }

    private(set) var state: State = .loading

    private let api: APIClient
    private let token: String

    init(api: APIClient, token: String) {
        self.api = api
        self.token = token
    }

    /// Load the preview. **Unauthenticated**, because you have to be able to see what a link is
    /// before you sign in to accept it.
    func load(isSignedIn: Bool) async {
        state = .loading
        do {
            let preview = try await api.invitePreview(token: token)
            state = .preview(preview, canAccept: isSignedIn)
        } catch let error as APIError {
            state = Self.classify(error)
        } catch {
            state = .unreachable(APIError.transport(error.localizedDescription).userMessage)
        }
    }

    /// Accept. Authenticated — the caller must be signed in, which the screen enforces by
    /// offering sign-in first rather than by letting this fail.
    func accept() async {
        state = .loading
        do {
            let accepted = try await api.acceptInvite(token: token)
            state = .joined(childCount: accepted.children.count)
        } catch let error as APIError {
            state = Self.classify(error)
        } catch {
            state = .unreachable(APIError.transport(error.localizedDescription).userMessage)
        }
    }

    /// One place that turns an `APIError` into a state, so the preview and the accept cannot
    /// disagree about what a given failure means.
    ///
    /// `nonisolated` because it is pure — no state, no clock, no network. That also makes it
    /// testable without a main-actor hop, which is the point: every branch here is a sentence
    /// somebody reads at the worst possible moment.
    nonisolated static func classify(_ error: APIError) -> State {
        switch error {
        case .api(let code, let message, _, _):
            switch code {
            case .notFound:
                return .noLongerValid
            case .conflict:
                // The household filled up between the link being sent and this tap. Its own
                // sentence, because it is the one refusal that is nobody's mistake and cannot
                // be retried into working.
                return .refused(message)
            case .unauthenticated, .tokenExpired:
                // Signed out underneath us. Not a broken invitation.
                return .refused("Sign in again, then open the link once more.")
            default:
                return .refused(message)
            }
        case .transport(let detail):
            return .unreachable(APIError.transport(detail).userMessage)
        case .sessionExpired:
            return .refused("Sign in again, then open the link once more.")
        case .decoding, .unexpectedStatus:
            return .unreachable(error.userMessage)
        }
    }
}
