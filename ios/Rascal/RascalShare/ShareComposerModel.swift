import Foundation
import Observation

/// What the share screen is doing, and the one write it makes.
///
/// Deliberately small. There is no network client here, no session and no SwiftData context — the
/// extension does not *choose* which child this is filing under, and does not need to. The app
/// resolves that at drain time from the session it already holds, which is also what keeps
/// multi-kid selection out of a twelve-second screen.
///
/// It does, however, have to record **whose** share this is. The App Group is the only thing this
/// process can see, and the app writes the signed-in child into it (`ShareInbox.currentOwner`), so
/// that is read once when the share opens and stamped into the record. Without it the queue is a
/// pile of photographs any account that later signs in on this phone would drain into its own
/// archive — see `ShareDrain.ingest`.
@MainActor
@Observable
final class ShareComposerModel {

    enum Phase: Equatable {
        /// Copying bytes in. A 4K video takes a moment and the screen says so.
        case staging
        /// Ready. The parent can type a note and save.
        case ready
        /// Nothing the share carried is something this app can hold, or the container is
        /// unreachable. Said plainly, with no way to save something that would be lost.
        case unusable(String)
    }

    private(set) var phase: Phase = .staging
    private(set) var loaded: [ShareItemLoader.Loaded] = []
    private(set) var isSaving = false

    /// Resolved once, when staging finishes, so the date on screen is the date that gets written.
    /// Recomputing it at save time would let a share left open across midnight save a different
    /// day than the one the parent read.
    private(set) var occurredAt = Date()
    private(set) var occurredAtSource: PendingShare.DateSource = .shareTime

    var note = ""

    private let inbox: ShareInbox
    /// Stamped once so `createdAt` is the moment the share opened rather than the moment Save was
    /// pressed — the two differ by however long someone spent typing, and the first is the honest
    /// answer to "when was this logged".
    private let openedAt: Date

    /// The child the app was signed in as when this share opened.
    ///
    /// **Read at staging, not at save**, and for a sharper reason than `openedAt`: a share sheet
    /// can sit open while somebody signs out of the app behind it. The share belongs to whoever
    /// was signed in when it was made, and re-reading the marker at save time would hand it to
    /// whoever is signed in now.
    private var ownerChildId: UUID?

    init(inbox: ShareInbox = .shared, openedAt: Date = Date()) {
        self.inbox = inbox
        self.openedAt = openedAt
        self.occurredAt = openedAt
    }

    var hasMedia: Bool { !loaded.isEmpty }

    /// Save is offered whenever there is something to file. **A note is optional and stays
    /// optional** — a photo on its own is a complete entry, and asking for a caption would be
    /// asking for homework at the one moment the product promises not to.
    var canSave: Bool { hasMedia && !isSaving }

    // MARK: Staging

    func stage(_ providers: [NSItemProvider]) async {
        guard inbox.directory != nil else {
            phase = .unusable(ShareCopy.unusableContainer)
            return
        }

        // **Before a single byte is copied.** A share with nobody to file it under is discarded by
        // the drain rather than filed under whoever signs in next, so staging a 4K video for it
        // would spend a parent's time and disk on something that ends in silence. Saying so now is
        // the honest version, and it names the one action that fixes it.
        guard let owner = inbox.currentOwner() else {
            phase = .unusable("Open Vellum and sign in, then share this again.")
            return
        }
        ownerChildId = owner

        loaded = await ShareItemLoader.load(providers, into: inbox)

        guard !loaded.isEmpty else {
            phase = .unusable(ShareCopy.unusableKind)
            return
        }

        let resolved = PendingShare.resolveOccurredAt(
            captures: loaded.map(\.item.capturedAt),
            now: openedAt
        )
        occurredAt = resolved.date
        occurredAtSource = resolved.source
        phase = .ready
    }

    // MARK: Saving

    /// Write the record. Returns whether the extension may complete its request.
    ///
    /// **One entry with several media, never one entry per photo.** Three pictures of the same
    /// afternoon are one thing that happened, and the composer has treated a multi-select that way
    /// since phase 2 — a share sheet producing three separate entries would fill a timeline with
    /// fragments of one moment.
    ///
    /// The record is the last thing written and it is written atomically, so this is the instant
    /// the share becomes real. Everything before it is bytes nothing references.
    func save() -> Bool {
        // `ownerChildId` is set the moment staging succeeds, so this cannot fail behind a screen
        // that offered Save — it is here so the record is built with a child rather than with an
        // optional that something downstream has to interpret.
        guard canSave, let ownerChildId else { return false }
        isSaving = true

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = PendingShare(
            createdAt: openedAt,
            occurredAt: occurredAt,
            occurredAtSource: occurredAtSource,
            ownerChildId: ownerChildId,
            note: trimmed.isEmpty ? nil : trimmed,
            media: loaded.map(\.item)
        )

        do {
            try inbox.write(record)
            return true
        } catch {
            isSaving = false
            phase = .unusable("This couldn't be saved. Open Vellum and add it from there.")
            return false
        }
    }

    /// The parent backed out. Remove the bytes staged for a share that will never have a record.
    ///
    /// Best effort, and it has a backstop: no record names these files, so `ShareInbox.sweepOrphans`
    /// collects anything this misses — including a dismissal the system never routes through a
    /// button, like a swipe down. Cleaning up here anyway means the common case does not wait for
    /// the next app launch to stop occupying disk.
    func discard() {
        for one in loaded {
            guard let url = inbox.mediaURL(for: one.item) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        loaded = []
    }
}
