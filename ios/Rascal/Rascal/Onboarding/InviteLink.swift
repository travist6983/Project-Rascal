import Foundation

/// A household invitation, as the app sees it.
///
/// The sibling of `SignInLink` and deliberately built the same way: a **universal link** rather
/// than a custom scheme, so the same `https://` URL opens the app when it is installed and a web
/// page when it is not. That matters more here than it does for a magic link — a magic link goes
/// to somebody who already has the app, and an invitation goes to the other parent, who may be
/// meeting Vellum for the first time on a laptop.
///
/// The claim is made in two places that have to agree, and nothing checks them at build time:
/// `Rascal.entitlements` lists `applinks:rascal-api.fly.dev`, and the API serves
/// `/.well-known/apple-app-site-association` naming `/invite/*` (phase 62). If either is wrong
/// the link opens Safari and **nothing anywhere reports an error**.
nonisolated struct InviteLink: Equatable, Sendable, Identifiable {
    let token: String

    /// The token *is* the identity — two links for the same invitation are the same invitation,
    /// and this drives a `fullScreenCover(item:)`.
    var id: String { token }

    /// The one path this claims. **`/invite/` and not `/invite`**: the token is a path component,
    /// so the prefix has to include the separator or `/invitations` would match.
    static let prefix = "/invite/"

    /// Parse a URL the system handed the app. Nil for anything that is not an invitation,
    /// including the claimed path with an empty token — an empty token produces a request the
    /// server can only answer with `404`, and a failure the parent cannot act on.
    ///
    /// The host is checked here as well as in the entitlement, for the reason `SignInLink` gives:
    /// iOS only hands the app links for domains it claims, so this is belt-and-braces — but the
    /// same parser is reachable from anywhere in the process, and a token we are about to POST
    /// should only ever have come from our own host.
    static func parse(_ url: URL, apiHost: String? = SignInLink.configuredHost) -> InviteLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "https",
            apiHost == nil || components.host?.lowercased() == apiHost?.lowercased(),
            components.path.hasPrefix(prefix)
        else { return nil }

        let token = String(components.path.dropFirst(prefix.count))
        // A trailing slash, a nested path, or nothing at all. None of them is a token.
        guard !token.isEmpty, !token.contains("/") else { return nil }
        return InviteLink(token: token)
    }
}
