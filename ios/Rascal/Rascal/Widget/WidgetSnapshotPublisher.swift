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
    /// **A snapshot identical to the stored one is not republished, and the reason is budget.**
    /// The write hook is `.onChange(initial: true)` on Today, and Today is destroyed and rebuilt
    /// every time the parent switches tabs — so browsing Timeline and coming back re-publishes a
    /// byte-for-byte identical file and asks WidgetKit to redraw for it. Widget refresh budget is
    /// finite and out of this app's control, and spending it on a redraw that cannot change a
    /// pixel is the easiest way to have none left when a completion actually needs one.
    ///
    /// **The reload is still requested even when the write fails.** A failed write leaves the
    /// previous snapshot in place, and that snapshot may well be yesterday's — asking for a redraw
    /// lets the widget re-run its own staleness check and fall back to the neutral state, which is
    /// the honest outcome. Staying quiet would leave the wrong day on the glass.
    func publish(_ snapshot: WidgetSnapshot?) {
        guard changed(to: snapshot) else { return }

        if let snapshot {
            store.write(snapshot)
        } else {
            store.clear()
        }
        reload()
    }

    /// Whether `snapshot` differs from what is already on disk.
    ///
    /// Compares decoded values rather than encoded bytes: `JSONEncoder` makes no promise about
    /// key order, so two encodings of the same snapshot are not guaranteed to be equal byte for
    /// byte, and comparing bytes would quietly stop suppressing anything.
    ///
    /// A file that cannot be read or decoded counts as different — that is the case where the
    /// widget is showing nothing or showing garbage, and the write is exactly what fixes it.
    private func changed(to snapshot: WidgetSnapshot?) -> Bool {
        guard let data = store.readData() else { return snapshot != nil }
        guard let stored = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return true
        }
        return stored != snapshot
    }
}
