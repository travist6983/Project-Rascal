import Foundation

/// The household, as Settings needs it: who is in it, who has been asked, and what happens when
/// a free-tier account tries to ask.
///
/// **The 402 is a state, not an error.** Per D4 the second guardian is what "one price for the
/// whole household" is sold on, so a free household hitting this has not done anything wrong and
/// is not being refused — they are meeting the upgrade surface. Folding it into the generic
/// error path would render it as a failure, which is exactly the wall the design rules forbid.
@MainActor
@Observable
final class GuardiansModel {

    enum Phase: Equatable {
        case idle
        case loading
        case ready(FamilySummary)
        /// The load failed. The section says so quietly and offers a retry; it does not vanish,
        /// because a household that disappears reads as a household that was lost.
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Set while an invite is being minted or revoked, so the row can disable itself rather
    /// than let a second tap create a second invite.
    private(set) var isWorking = false
    /// The one-time link, held only long enough to hand to the share sheet.
    private(set) var pendingShareURL: URL?
    /// True when the household is free and an invite was attempted. Drives the upgrade sheet.
    private(set) var showsUpgrade = false
    /// A refusal that is neither the paywall nor a load failure — the household is already full,
    /// or the link could not be withdrawn. Shown as a sentence, never an alert.
    private(set) var notice: String?

    private let api: APIClient
    private let inviteBaseURL: URL?

    init(api: APIClient, inviteBaseURL: URL? = GuardiansModel.configuredBase) {
        self.api = api
        self.inviteBaseURL = inviteBaseURL
    }

    var family: FamilySummary? {
        if case .ready(let family) = phase { return family }
        return nil
    }

    func load() async {
        if case .ready = phase {} else { phase = .loading }
        do {
            phase = .ready(try await api.family())
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed(APIError.transport(error.localizedDescription).userMessage)
        }
    }

    /// Mint an invite and hand back a shareable URL, **once**.
    ///
    /// The server stores only the token's SHA-256, so if the share sheet is dismissed the link
    /// is genuinely gone and a new invite has to be created. The UI says that in one line rather
    /// than offering a "copy again" that cannot work.
    func invite() async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        do {
            let created = try await api.createInvite()
            if let url = Self.shareURL(token: created.token, base: inviteBaseURL) {
                pendingShareURL = url
            } else {
                // No configured host, so there is no link to hand over. Saying so beats
                // presenting a share sheet containing nothing usable.
                notice = "This build has no server configured, so there is no link to send."
            }
            await load()
        } catch let error as APIError {
            switch error.code {
            case .subscriptionRequired:
                showsUpgrade = true
            case .conflict:
                // Two adults is the household. Not an upsell — a third is a different product.
                notice = error.userMessage
                await load()
            default:
                notice = error.userMessage
            }
        } catch {
            notice = APIError.transport(error.localizedDescription).userMessage
        }
    }

    func revoke(_ invite: InviteSummary) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        do {
            try await api.revokeInvite(id: invite.id)
            await load()
        } catch let error as APIError {
            notice = error.userMessage
        } catch {
            notice = APIError.transport(error.localizedDescription).userMessage
        }
    }

    func shareSheetDismissed() { pendingShareURL = nil }
    func upgradeDismissed() { showsUpgrade = false }
    func noticeDismissed() { notice = nil }

    /// The API base, from `Config.xcconfig` via Info.plist per rule 5 — the same key
    /// `SignInLink` reads, so the invite link and the magic link cannot end up on different
    /// hosts. Nil when unreadable, which makes the invite row report rather than build a URL
    /// pointing at nothing.
    nonisolated static var configuredBase: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        else { return nil }
        return URL(string: raw)
    }

    /// The link a parent sends. **The token is the whole secret**, so it goes in the path of a
    /// URL the app claims, and nowhere else.
    ///
    /// **A universal link and deliberately not a custom scheme.** The same reasoning as
    /// `SignInLink`: an `https://` URL opens the app when installed and a web page when not,
    /// where `rascal://` gives a spouse on a laptop a browser error about a scheme it has never
    /// heard of. There is no registered URL scheme in this app and this is not the phase to
    /// invent one.
    ///
    /// **This link does not open the app yet**, and that is a cross-lane dependency rather than
    /// an oversight: the served association file claims `/signin` alone
    /// (`api/src/rascal/routers/wellknown.py`), so `/invite/...` is not matched. Widening it is
    /// an `api/` change, and `ios/CLAUDE.md` says say so and stop rather than patch the backend.
    nonisolated static func shareURL(token: String, base: URL?) -> URL? {
        guard let base else { return nil }
        return base.appendingPathComponent("invite").appendingPathComponent(token)
    }
}
