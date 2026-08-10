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
/// So this writes bytes and a record into the App Group container and gets out of the way.
/// `ShareDrain`, in the app, does the rest through the pipeline the composer already uses.
///
/// `UIViewController` hosting SwiftUI rather than `SLComposeServiceViewController`: the system
/// composer draws its own chrome and its own type, and none of it is this product's.
final class ShareViewController: UIViewController {

    private let model = ShareComposerModel()
    private var hasCompleted = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // **Light, explicitly.** "Light mode only for now" is settled for the app
        // (docs/decisions.md), and the widget's dark palette is an exception granted because a
        // widget has no `preferredColorScheme` and cannot opt out. A share extension can, so the
        // app's rule applies here unchanged and no second dark-mode decision is being taken.
        overrideUserInterfaceStyle = .light

        let composer = ShareComposer(
            model: model,
            onSave: { [weak self] in self?.save() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: composer)
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

        Task { await model.stage(providers()) }
    }

    /// **A dismissal the buttons never saw.** A share sheet can be swiped away, and the system
    /// tears the extension down without routing through Cancel. Files staged for a share that will
    /// never have a record would otherwise sit in the container until the app's orphan sweep found
    /// them; discarding here means the common case cleans up immediately.
    ///
    /// Guarded on `hasCompleted`, because a successful save also dismisses this view controller —
    /// and discarding *then* would delete the bytes the record it just wrote points at.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !hasCompleted else { return }
        model.discard()
    }

    /// Every attachment the share carried, flattened.
    ///
    /// A share can arrive as several input items each holding several attachments — selecting
    /// photos in one app and videos in another is the ordinary way to produce that shape — and all
    /// of them belong to one entry.
    private func providers() -> [NSItemProvider] {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        return items.flatMap { $0.attachments ?? [] }
    }

    private func save() {
        guard model.save() else { return }
        hasCompleted = true
        // Nothing to hand back: the record is on disk and the app owns it now. `completeRequest`
        // is the last thing that happens, because once it returns the source URLs are gone — and
        // the bytes have already been copied, which is the point of doing it in that order.
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        model.discard()
        hasCompleted = true
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
