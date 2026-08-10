import Foundation
import WidgetKit

/// Writes the snapshot and tells WidgetKit to redraw.
///
/// The two belong together and are therefore one call. A write nobody is told about shows up
/// whenever the system next feels like refreshing an extension, which can be hours — the app
/// pushing a reload is what makes the widget current within seconds, and the timeline is only the
/// backstop for a day boundary nobody is awake for.
///
/// The reload is injected so a test can watch for it. `WidgetCenter` does nothing under a test
/// runner and reports nothing back, so a spy is the only way to assert that completing an
/// assignment actually asked for a redraw.
nonisolated struct WidgetSnapshotPublisher: Sendable {

    let store: WidgetSnapshotStore
    let reload: @Sendable () -> Void

    init(
        store: WidgetSnapshotStore,
        reload: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.store = store
        self.reload = reload
    }

    static var live: WidgetSnapshotPublisher {
        WidgetSnapshotPublisher(store: .shared)
    }

    /// Publish a snapshot, or clear it when there is nothing to show.
    ///
    /// **The reload is requested even when the write fails.** A failed write leaves the previous
    /// snapshot in place, and that snapshot may well be yesterday's — asking for a redraw lets
    /// the widget re-run its own staleness check and fall back to the neutral state, which is the
    /// honest outcome. Staying quiet would leave the wrong day on the glass.
    func publish(_ snapshot: WidgetSnapshot?) {
        if let snapshot {
            store.write(snapshot)
        } else {
            store.clear()
        }
        reload()
    }
}
