import SwiftData
import SwiftUI

struct RootView: View {
    /// Owned by `OnboardingGate` and handed down, so the whole process shares one `APIClient`
    /// and one single-flight refresh. Two would race a rotating refresh token against itself.
    let session: AppSession
    /// Resolved by the gate before this view exists.
    ///
    /// **This view no longer resolves session state, and that is the point.** It used to run
    /// `AppSession.start()` itself, which re-fetched a child the gate had already fetched and —
    /// on a network blip in that window — fell through to `dev-login`, so a signed-in parent in
    /// production could be told "the API is not running with ENVIRONMENT=local". One owner of
    /// session state, and it is the gate.
    let childId: UUID
    /// The zone the server computes this child's schedule in, as the gate resolved it at launch.
    /// Passed through to Today, which stamps it onto the widget snapshot so the widget can tell
    /// today's board from yesterday's without asking anyone.
    let familyTimezone: String
    /// `YYYY-MM-DD`, as the gate resolved it at launch.
    ///
    /// Only the camera-roll backfill reads it, and only to say how old the child was in a month
    /// that has nothing written in it — where there is no server-computed `child_age_months` to
    /// render, because no entry exists to carry one.
    let childBirthdate: String
    /// The zone after Settings has seen a newer one.
    ///
    /// **The gate resolves the child once, at launch, and never again for the life of the
    /// session** — so editing the child's timezone in Settings, or having it changed on another
    /// device, would otherwise leave every snapshot written afterwards stamped with the old zone.
    /// A staleness check run against the wrong zone is precisely how yesterday's mission reaches
    /// the Home Screen dressed as today's, so the newer value wins here rather than waiting for
    /// a relaunch.
    @State private var resolvedTimezone: String?

    private var timezone: String { resolvedTimezone ?? familyTimezone }

    /// The child's name and pronouns, as the gate resolved them at launch.
    ///
    /// **There is no stored fallback and none is needed.** The gate cannot reach `.ready` without
    /// a successful `GET /children`, so by the time any prompt is on screen this is already the
    /// server's answer — there is no window in which a body would render they/them and then flip.
    let initialPromptSubject: PromptSubject
    /// The subject after Settings has written a newer one.
    ///
    /// Same reason `resolvedTimezone` exists: the gate resolves the child once per session, so a
    /// pronoun changed in Settings would otherwise not reach a single prompt until relaunch. The
    /// spec's requirement that a change take effect on already-rendered prompts is satisfied here
    /// and nowhere else — everything downstream reads the environment, so `@Observable` redraws
    /// every card the moment this changes.
    @State private var resolvedPromptSubject: PromptSubject?

    private var promptSubject: PromptSubject { resolvedPromptSubject ?? initialPromptSubject }
    /// Handed down to Settings. The gate owns signing out, because it is the only thing that can
    /// put the app back on the welcome screen afterwards.
    let onSignOut: () async -> Void
    /// The one `NotificationPreference` in the process, owned by `OnboardingGate`. Handed down
    /// rather than rebuilt: a second instance would keep its own copy of whether the single
    /// post-entry re-offer had been spent, and would offer it again.
    let notifications: NotificationPreference
    /// A widget tap the gate caught, possibly before this view existed. Consumed and cleared
    /// below.
    @Binding var pendingLink: WidgetDeepLink?
    /// **Owned here rather than by `TodayScreen`, because the widget outlives the tab.** The tab
    /// switch destroys Today, and with it every `@Query` that would notice the archive changing —
    /// so an entry deleted from Entry Detail, two tabs away, left the Home Screen showing a
    /// completion check on a prompt with nothing behind it. `WidgetSnapshotSync` reads this model
    /// from the root, where nothing tears it down.
    @State private var todayModel: TodayModel
    @State private var tab: Tab = .today
    @State private var composer: ComposerRequest?
    /// An assignment the widget asked for, waiting for Today to have a board to resolve it
    /// against. Cleared whether or not it resolves — see `TodayScreen`.
    @State private var requestedAssignment: UUID?
    @State private var sync: EntrySync?
    @State private var syncEngine: SyncEngine?
    @State private var mediaCoordinator: MediaCoordinator?
    /// Files the share extension staged into the App Group container, waiting to become entries.
    ///
    /// Owned here rather than by a screen for the same reason `todayModel` is: a share is drained
    /// on launch and on every foreground, and neither of those is a tab. Built here because this
    /// is where the child is — the extension deliberately does not know which child a share is
    /// for, and this view has the one the gate resolved.
    @State private var shareDrain: ShareDrain?
    /// One transcriber for the process, for the same reason there is one upload coordinator:
    /// **no parallel inference.** Two queues would mean two `SpeechAnalyzer`s warming the phone
    /// at once, which is a real cost on a device someone is holding.
    @State private var transcription: TranscriptionQueue?
    /// One extractor for the process, for the same reason there is one transcriber: **no
    /// parallel inference.** Two model sessions warming the phone at once is a real cost on a
    /// device someone is holding. Deliberately not tied to `MediaCoordinator` the way the
    /// transcriber is — extraction reads text, so it has nothing to do with media landing.
    @State private var extraction: ExtractionQueue?
    /// One picture cache for the whole app, so the timeline, Moments, and a detail screen all
    /// draw from the same fetches rather than each pulling the same photo down again.
    @State private var thumbnails: ThumbnailStore?
    /// The one post-entry notification re-offer. See `considerNotificationReoffer`.
    @State private var showingNotificationReoffer = false
    /// **One scanner for the process**, for the same reason there is one transcriber: a scan walks
    /// the whole photo library, and two of them would walk it twice concurrently on a device
    /// someone is holding. Owned here rather than by a screen because the **+** sheet needs the
    /// answer before any backfill screen exists.
    @State private var backfill: BackfillScanner?
    /// The PhotoKit seam, held so the flow and the scanner share one.
    @State private var backfillSource: (any BackfillAssetSource)?
    /// What the **+** sheet chose, held until it has finished dismissing. Presenting from a sheet
    /// on its way out drops the presentation, so the root acts on this in `onDismiss`.
    @State private var pendingAdd: AddToArchiveChoice?
    @State private var showingAddSheet = false
    @State private var showingBackfill = false
    /// The floating bar's measured height, reported by the bar itself.
    ///
    /// Seeded at roughly what the current design produces at the default text size — a ~64pt
    /// capsule plus the disc's protrusion — so the very first frame, before the measurement
    /// lands, insets by about the right amount rather than by nothing. Every frame after that
    /// uses what was actually laid out, at whatever text size the phone is set to.
    @State private var tabBarHeight: CGFloat = 78

    /// The gap between the bar and the bottom safe area. One constant, used both to place the bar
    /// and to inset the content behind it, so the two cannot drift.
    static let tabBarFloatGap: CGFloat = 4

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    init(
        session: AppSession,
        childId: UUID,
        familyTimezone: String,
        childBirthdate: String,
        promptSubject: PromptSubject,
        onSignOut: @escaping () async -> Void,
        notifications: NotificationPreference,
        pendingLink: Binding<WidgetDeepLink?>
    ) {
        self.session = session
        self.childId = childId
        self.familyTimezone = familyTimezone
        self.childBirthdate = childBirthdate
        self.initialPromptSubject = promptSubject
        self.onSignOut = onSignOut
        self.notifications = notifications
        self._pendingLink = pendingLink
        // Written by hand for one property, the same way `ComposerView` does: the model needs the
        // child and the client, and a `@State` default cannot see either.
        self._todayModel = State(initialValue: TodayModel(childId: childId, api: session.api))
    }

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            signedIn(childId: childId)
            // Draws nothing. Holds the queries that keep the widget's snapshot in step with the
            // archive whichever tab is showing.
            WidgetSnapshotSync(
                model: todayModel,
                familyTimezone: timezone,
                // **Rendered before the snapshot is written, not in the extension.** The widget
                // reads a file and does no networking, so it has no child and no environment —
                // the tokens have to be gone by the time the bytes land in the App Group. This is
                // also why a pronoun change has to republish, which it does: the subject is part
                // of the snapshot's identity, so `onChange` fires.
                subject: promptSubject
            )
        }
        .task {
            if thumbnails == nil {
                thumbnails = ThumbnailStore(api: session.api)
            }
            if mediaCoordinator == nil {
                let coordinator = MediaCoordinator(api: session.api)
                mediaCoordinator = coordinator
                // The upload delegate reaches back through this after a background callback;
                // it has no other way to make an authenticated call.
                MediaCoordinator.shared = coordinator
                // Claim the background session now so tasks outstanding from a previous launch
                // reattach to this delegate rather than reporting to nobody.
                MediaUploader.shared.activate()
            }
            if extraction == nil {
                extraction = ExtractionQueue(api: session.api, context: context)
            }
            if transcription == nil, let mediaCoordinator {
                let queue = TranscriptionQueue(api: session.api, context: context)
                transcription = queue
                // The link the coordinator uses to consider a recording the moment its upload
                // lands. One direction — the queue does not hold the coordinator.
                mediaCoordinator.transcription = queue
            }
            if sync == nil {
                sync = EntrySync(api: session.api, context: context, media: mediaCoordinator)
            }
            if shareDrain == nil {
                shareDrain = ShareDrain(context: context, childId: childId)
            }
            if backfill == nil {
                let source = PhotoLibraryBackfillSource()
                backfillSource = source
                backfill = BackfillScanner(source: source)
            }
            // The engine needs the child, which the gate has already resolved.
            if syncEngine == nil {
                syncEngine = SyncEngine(
                    childId: childId,
                    api: session.api,
                    context: context,
                    state: UserDefaultsSyncStateStore(),
                    push: sync
                )
            }
            await runSweep()
            scanForBackfill()
        }
        // Entries saved while offline live in SwiftData until something re-sends them. This is
        // that something: without it, local-first saving keeps the work and never delivers it.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await runSweep() }
                // `force: false`, so the cache does its job. A foreground is not a reason to walk
                // forty thousand assets again.
                scanForBackfill()
            }
            // A tap the app never managed to act on — Today failed to load, so the board that
            // would resolve it never appeared — does not survive the app being put away. It would
            // otherwise sit there and open a composer on some later launch, for a prompt the
            // parent tapped hours ago and has forgotten.
            if phase == .background { requestedAssignment = nil }
        }
        // The widget's way back into the app, in the middle of a three-step route: the gate
        // catches the URL, this turns it into a tab and a request, and Today resolves the request
        // against the board. Each step knows exactly one thing — the gate knows URLs, this knows
        // tabs, Today knows assignments.
        //
        // **`initial: true` is what makes a cold launch work.** iOS delivers the URL while the
        // gate is still resolving the session, which is well before this view exists; the gate
        // holds it, and this fires on the first render with the value already set. Catching the
        // URL here instead — which is where it started — dropped every launch-from-widget tap,
        // and a widget tapped on a phone where the app is not already running is the normal case,
        // not the edge one.
        .onChange(of: pendingLink, initial: true) { _, link in
            guard let link else { return }
            // Cleared first and unconditionally, so a request that resolves to nothing cannot
            // re-fire on the next render.
            pendingLink = nil
            tab = .today
            // **A tap supersedes any earlier one that never resolved.** Without this, tapping a
            // Lock Screen widget that only asks for Today would leave an older, unresolved
            // assignment request standing — and that one would fire as soon as the board loaded,
            // opening a composer for a prompt the parent had moved on from.
            requestedAssignment = nil
            // A composer already open belongs to whatever the parent was doing before the tap.
            // Replacing it would discard typed words, so the link takes them to Today instead.
            guard composer == nil else { return }
            if case .assignment(let id) = link { requestedAssignment = id }
        }
        // **The guard above is not enough on its own, because the request is deferred.** Today
        // resolves it only once the board has loaded, and in that window the parent can open a
        // composer themselves — the centre button, or a card on Today. When they do, the sheet is
        // theirs; a widget tap still waiting for a board must not replace it and discard what they
        // have typed. Checking at the moment the link arrives cannot see a composer that does not
        // exist yet, so ownership is settled here instead.
        .onChange(of: composer != nil) { _, isOpen in
            if isOpen { requestedAssignment = nil }
        }
        .sheet(item: $composer, onDismiss: {
            Task {
                await runSweep()
                considerNotificationReoffer()
                // An entry just written may have filled a month the scan was offering. Appended
                // to the callers already here rather than replacing any of them.
                //
                // **Before `extractLatest`, and not for tidiness.** The scan is non-blocking — it
                // kicks a task and returns — while extraction awaits an on-device model and can
                // take seconds. Ordered the other way, the **+** sheet would keep offering a month
                // the parent has just written in for as long as inference ran.
                scanForBackfill(force: true)
                await extractLatest()
            }
        }) { request in
            ComposerView(request: request, api: session.api)
        }
        .sheet(isPresented: $showingAddSheet, onDismiss: consumePendingAdd) {
            AddToArchiveSheet(model: addToArchiveModel) { pendingAdd = $0 }
        }
        .fullScreenCover(isPresented: $showingBackfill) {
            if let backfill, let backfillSource {
                BackfillFlowView(
                    childId: childId,
                    childBirthdate: resolvedBirthdate,
                    api: session.api,
                    scanner: backfill,
                    source: backfillSource,
                    entryDates: { entryOccurredDates() },
                    onComposerDismiss: {
                        await runSweep()
                        considerNotificationReoffer()
                    }
                )
            }
        }
        .sheet(isPresented: $showingNotificationReoffer) {
            NotificationReofferSheet(preference: notifications, familyTimezone: timezone)
        }
    }

    /// What the **+** sheet shows.
    ///
    /// **The camera-roll row is in it in every state.** It used to be conditioned on this list
    /// being non-empty, and the list is empty until a scan has produced clusters — which needs
    /// authorization, which is only ever asked for by the explainer that lives behind the row.
    /// A phone that had never granted access therefore never saw the row and never could.
    private var addToArchiveModel: AddToArchiveModel {
        guard let backfill else { return AddToArchiveModel() }
        let clusters: [BackfillCluster]
        if case .ready(let ready) = backfill.state { clusters = ready } else { clusters = [] }
        return AddToArchiveModel(authorization: backfill.authorization, clusters: clusters)
    }

    /// Acted on after the sheet has gone, never during. See `pendingAdd`.
    private func consumePendingAdd() {
        guard let choice = pendingAdd else { return }
        pendingAdd = nil
        switch choice {
        case .compose(let opening):
            composer = ComposerRequest(
                childId: childId,
                assignment: nil,
                // `.text` as before: a freeform entry can hold photos, a voice note, or nothing
                // but words, and the verb chosen only decides what opens on top of it.
                mode: .text,
                opening: opening
            )
        case .backfill:
            showingBackfill = true
        }
    }

    /// The birthdate as a day, for the flow's age lines only.
    ///
    /// Read through the same day-only calendar `EditChildModel` uses, so a June birthday cannot
    /// render as May. Nil parses to no age line rather than to a wrong one.
    private var resolvedBirthdate: Date? {
        EditChildModel.dayFormatter.date(from: childBirthdate)
    }

    /// Every `occurred_at` this device holds.
    ///
    /// **Compared locally and never by asking the server** — the server has no idea what is in this
    /// camera roll, and a round trip per month would make a forty-thousand-asset library unusable.
    private func entryOccurredDates() -> [Date] {
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        // Only the dates are wanted; nothing here reads a body or a relationship.
        descriptor.propertiesToFetch = [\.occurredAt]
        return (try? context.fetch(descriptor).map(\.occurredAt)) ?? []
    }

    private func scanForBackfill(force: Bool = false) {
        backfill?.scan(entryDates: entryOccurredDates(), force: force)
    }

    /// The single permitted re-offer, after the first completed entry.
    ///
    /// Gated on there actually being an entry rather than on the composer having been dismissed:
    /// a parent who opened the composer, thought better of it, and swiped it away has completed
    /// nothing, and offering here would spend the one re-offer on a moment that has not earned
    /// it. `shouldReofferAfterFirstEntry` carries the rest of the rule — it is false unless the
    /// parent chose "Not now", false once the offer has been spent, and false forever after a
    /// system-level denial.
    private func considerNotificationReoffer() {
        guard notifications.shouldReofferAfterFirstEntry else { return }
        var descriptor = FetchDescriptor<Entry>()
        descriptor.fetchLimit = 1
        guard let count = try? context.fetchCount(descriptor), count > 0 else { return }
        notifications.markReofferShown()
        showingNotificationReoffer = true
    }

    private func signedIn(childId: UUID) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .today:
                    TodayScreen(
                        childId: childId,
                        api: session.api,
                        familyTimezone: timezone,
                        requestedAssignment: $requestedAssignment,
                        onRetrySync: { Task { await runSweep() } },
                        onSync: { await runSweep() },
                        openComposer: { composer = $0 },
                        model: todayModel
                    )
                case .timeline:
                    // Pull to refresh is a sync trigger: the gesture means "show me what is
                    // actually there", and page one of `GET /entries` is only half of that.
                    TimelineScreen(
                        childId: childId,
                        api: session.api,
                        onSync: { await runSweep() }
                    ) { composer = $0 }
                case .moments:
                    MomentsScreen(childId: childId, api: session.api) { composer = $0 }
                case .settings:
                    SettingsScreen(
                        childId: childId,
                        session: session,
                        onSignOut: onSignOut,
                        sync: sync,
                        syncEngine: syncEngine,
                        transcription: transcription,
                        notifications: notifications,
                        onTimezoneResolved: { resolvedTimezone = $0 },
                        onPromptSubjectChanged: { resolvedPromptSubject = $0 }
                    )
                case .create:
                    // The centre button opens the composer as a sheet and never selects a tab,
                    // so this is unreachable. Today is what the app falls back to rather than a
                    // blank screen, on the principle that a fallback should be somewhere real.
                    TodayScreen(
                        childId: childId,
                        api: session.api,
                        familyTimezone: timezone,
                        openComposer: { composer = $0 },
                        model: todayModel
                    )
                }
            }
            .environment(\.thumbnails, thumbnails)
            // Set once, above every tab. A prompt body reaches a human on Today, in the composer,
            // on a timeline card and on Entry Detail, and all four have to read the same answer —
            // a renderer applied in three of them produces an archive where the same sentence
            // depends on which screen you opened it from.
            .promptSubject(promptSubject)
            // **Clear the floating bar so the last card is never trapped underneath it — by what
            // the bar actually measures, not by a number kept in step by hand.**
            //
            // This was a hardcoded 84. The bar is a capsule whose height follows Dynamic Type,
            // plus a disc lifted 16pt out of its top, plus the float gap below it — so 84 was
            // right for one text size and one FAB geometry and silently wrong either side of
            // that. "Retry now" rendering under the bar is what that looks like from the outside.
            //
            // Applied to the `Group`, so it reaches **every** tab rather than the ones somebody
            // remembered: Today, Timeline, Moments and Settings all scroll behind this bar.
            .safeAreaPadding(.bottom, tabBarHeight + Self.tabBarFloatGap)

            // **The centre button opens a sheet rather than the composer, and that is a
            // reversal** — see `docs/decisions.md`. It costs a tap on the way to every entry,
            // which is the price of the camera roll having a home that is a browse action rather
            // than a fifth capture verb buried in a form.
            FloatingTabBar(
                selection: $tab,
                onCreate: { showingAddSheet = true },
                onHeightChange: { tabBarHeight = $0 }
            )
            .padding(.bottom, Self.tabBarFloatGap)
        }
    }
}

extension RootView {
    /// Push whatever has not landed, then apply whatever the server has.
    ///
    /// **The order is the engine's, not this function's.** `SyncEngine.pull` drains the push
    /// queue itself before applying anything, because pulling first can hand back a stale server
    /// row that overwrites a local edit which has not been pushed yet. Calling it here rather
    /// than sweeping separately is what keeps that ordering in one place.
    ///
    /// With `syncPullEnabled` off — which is how this ships — `pull()` drains the queue and
    /// returns without reading `/sync`, so this is exactly the behaviour that was here before.
    ///
    /// **The share queue brackets the sweep, and the order is the point.**
    ///
    /// `ingest` first, so a photo shared while the app was closed is an ordinary local entry
    /// before anything is pushed — it then rides the same queue, the same retries and the same
    /// entries-before-media ordering as everything the composer wrote, rather than getting a
    /// second path of its own.
    ///
    /// `reap` last, because the rule is that staged files go only once the server has confirmed
    /// the entry, and the sweep in between is what obtains that confirmation. Reaping first would
    /// mean a failed `POST /entries` had already thrown away the only copy of the photo — the
    /// bytes exist nowhere else once Photos is closed.
    /// Structure the entry the parent just wrote, if this phone can.
    ///
    /// **Names one row and never enumerates.** The candidate list is reduced to the newest here
    /// rather than walked, which is what keeps a first launch from running inference over six
    /// years of archive — the same restraint `TranscriptionQueue.enqueue` shows.
    ///
    /// Every rule beyond that is the queue's: a sealed entry is refused before its body is read,
    /// an already-extracted one is skipped, and a phone that cannot run the model does nothing
    /// and says nothing about it.
    private func extractLatest() async {
        guard let extraction else { return }
        guard let newest = ExtractionQueue.pending(in: context)
            .max(by: { $0.createdAt < $1.createdAt })
        else { return }
        await extraction.extract(entryId: newest.id)
    }

    private func runSweep() async {
        await shareDrain?.ingest()
        if let syncEngine {
            await syncEngine.pull()
        } else {
            await sync?.sweep()
        }
        shareDrain?.reap()
    }
}

