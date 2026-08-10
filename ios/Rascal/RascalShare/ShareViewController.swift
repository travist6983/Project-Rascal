import SwiftUI
import UIKit

/// The share extension's entry point, named by `NSExtensionPrincipalClass` in
/// `RascalShare-Info.plist`.
///
/// **This target stages and exits. It never uploads, never authenticates, and makes no network
/// request of any kind** — see `docs/decisions.md`. Three reasons, all of which have already cost
/// someone time on this project or one like it:
///
///  1. A share extension runs under a hard memory ceiling. Video will exceed it, and a transcode
///     or an upload inside this process is a crash waiting for a large file.
///  2. A token refresh running inside an extension, concurrently with the app, can invalidate the
///     app's own session. The failure is intermittent and very hard to attribute. The widget was
///     given no way to make one for the same reason.
///  3. The standing sync rule is that an entry is confirmed server-side *before* its media upload
///     is attempted, because `POST /media/upload-url` needs an `entry_id` the server recognises.
///     An extension that uploaded independently would break that ordering and produce 404s.
///
/// `UIViewController` hosting SwiftUI rather than `SLComposeServiceViewController`: the system
/// composer draws its own chrome and its own type, and none of it is this product's.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // **Light, explicitly.** "Light mode only for now" is settled for the app
        // (docs/decisions.md), and the widget's dark palette is an exception granted because a
        // widget has no `preferredColorScheme` and cannot opt out. A share extension can, so the
        // app's rule applies here unchanged and no second dark-mode decision is being taken.
        overrideUserInterfaceStyle = .light

        let host = UIHostingController(rootView: ShareRootView())
        host.view.backgroundColor = UIColor(Color.canvas)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}

/// One neutral line. The target exists, embeds and compiles; nothing is staged yet.
///
/// Deliberately the whole of this commit's behaviour — target creation is committed separately
/// from the feature so it reverts cleanly if the project stops building.
private struct ShareRootView: View {
    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            Text("Nothing to save yet.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
    }
}
