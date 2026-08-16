import Foundation

/// The magic link, as the app sees it.
///
/// A **universal link** rather than a custom scheme, and the difference is the point: the same
/// `https://` URL opens the app when it is installed and a web page when it is not. A parent who
/// taps the link on a laptop gets a page telling them where to go, instead of a browser error
/// about a scheme it has never heard of.
///
/// The claim is made in two places that have to agree, and nothing checks them at build time:
/// `Rascal.entitlements` lists `applinks:rascal-api.fly.dev`, and the API serves
/// `/.well-known/apple-app-site-association` naming this exact path. If either is wrong the link
/// opens Safari and **nothing anywhere reports an error** — which is why the API has a test
/// asserting the served path and the configured link base still match.
nonisolated struct SignInLink: Equatable, Sendable {
    let token: String

    /// The one path the app claims. Deliberately narrow: claiming `*` on the API host would make
    /// the app intercept `/health`, presigned media URLs and anything a browser client ever
    /// serves there.
    static let path = "/signin"

    /// Parse a URL the system handed the app. Returns nil for anything that is not a sign-in
    /// link, including a claimed path with no token — an empty token would produce a request the
    /// server can only answer with `401`, and a failure the parent cannot act on.
    static func parse(_ url: URL) -> SignInLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.path == path,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { return nil }
        return SignInLink(token: token)
    }
}
