import SafariServices
import SwiftUI

/// A web page, **inside this app.**
///
/// Review requires Terms of Use and a Privacy Policy on any screen selling a subscription, and a
/// SwiftUI `Link` opens both by handing the reader to Safari. For a reviewer checking guideline
/// 3.1.2 that means leaving the app under review halfway through the check — which is the specific
/// thing phase 124's brief calls out, and the whole of why this type exists.
///
/// **A `UIViewControllerRepresentable` because SwiftUI has no equivalent**, and the same shape
/// `ShareLinkSheet` (`GuardiansSection.swift`) and `CameraPicker` already are. `SafariServices` is
/// first-party, so rule 4's ban on third-party dependencies is not in play.
///
/// **In `DesignSystem/` rather than beside one caller.** Two surfaces present it — the paywall's
/// `legalRow` and Settings' `About` section — and neither owns it. Terms and Privacy are
/// reachable-from-anywhere legal pages rather than a subscription concern.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        // **Reader off.** Neither page is an article, and Reader on a terms page strips the
        // structure a reader needs to find a clause.
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        // Safari's own bar is chrome rather than text, so the 3:1 non-text threshold applies and
        // `terracotta` clears it at 4.36:1. This is not `foregroundStyle` on body copy, which is
        // the case `terracottaDeep` exists for.
        controller.preferredControlTintColor = UIColor(Color.terracotta)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// One legal page, identified by its own address, so `.sheet(item:)` can present it.
///
/// **A wrapper rather than `extension URL: Identifiable`.** Conforming a Foundation type to a
/// Foundation protocol from this module is a retroactive conformance, which the compiler warns
/// about and which would apply to every `URL` in the app to serve one sheet.
///
/// **Named `LegalPage`, not `WebPage`.** `WebKit.WebPage` exists as of iOS 26; a module-local type
/// of that name resolves in our favour but reads as a shadow of a system type to the next person.
struct LegalPage: Identifiable {
    let url: URL
    var id: URL { url }
}
