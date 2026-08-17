import Foundation

/// Asking for the account to be deleted.
///
/// **Requesting signs you out, and that has a consequence worth stating plainly:** the server
/// revokes every refresh token, so the app cannot stay signed in, and the explicit cancel
/// endpoint is not the route a parent will ever take. **Signing back in is the cancel** — the
/// server does it on any sign-in, per D3's precedent, and that is the mechanism this screen
/// tells them about rather than a button it cannot reliably offer.
///
/// The alternative — staying signed in with a pending banner and a Cancel button — was not
/// available: it contradicts "signed out immediately", and it would make cancel-on-sign-in
/// unsafe, because a phone in a drawer rotating its token would cancel a deletion its owner
/// still wanted.
@MainActor
@Observable
final class AccountDeletionModel {

    enum State: Equatable {
        case idle
        case working
        /// Requested. `executeAfter` is what the confirmation reads back to them.
        case scheduled(executeAfter: Date)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let api: APIClient
    private var isPreview = false

    init(api: APIClient) {
        self.api = api
    }

    #if DEBUG
        init(previewing state: State) {
            self.api = APIClient(
                baseURL: URL(string: "https://preview.invalid")!,
                tokens: InMemoryTokenStore()
            )
            self.isPreview = true
            self.state = state
        }
    #endif

    var scheduledDate: Date? {
        if case .scheduled(let date) = state { return date }
        return nil
    }

    /// Ask. On success the caller signs out, because the session is already dead server-side.
    func request() async {
        if isPreview { return }
        guard state != .working else { return }
        state = .working
        do {
            let scheduled = try await api.requestAccountDeletion()
            state = .scheduled(executeAfter: scheduled.executeAfter)
        } catch let error as APIError {
            state = .failed(error.userMessage)
        } catch {
            state = .failed(APIError.transport(error.localizedDescription).userMessage)
        }
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }
}
