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

    /// The server's `age_months`, straight off the Today response. **Never computed here** — a
    /// client that works out an age drifts the moment a rounding rule differs, which is why
    /// `ChildSummary.ageMonths` says so in those words.
    private var childAgeMonths: Int? {
        if case .loaded(let response) = todayModel.state { return response.child.ageMonths }
        return nil
    }

    /// Handed down to Settings. The gate owns signing out, because it is the only thing that can
    /// put the app back on the welcome screen afterwards.
    let onSignOut: () async -> Void

    /// Open the child switcher, or nil when there is nowhere to switch to.
    ///
    /// **Passed straight through to the pill without being interpreted.** The decision about
    /// whether a second child exists belongs to the gate — see `OnboardingSession.canSwitchChild`
    /// — and this view deliberately does not second-guess it, because a `RootView` that decided
    /// for itself would need the child list, which is exactly the state the gate owns.
    let onSwitchChild: (() -> Void)?

    /// Open the add-a-child sheet. Threaded to Settings, and — unlike `onSwitchChild` — never nil:
    /// an account with one child is exactly the one that needs it.
    let onAddChild: () -> Void
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
    /// **One `SubscriptionModel` above every tab, and there must be exactly one.**
    ///
    /// It was `@State` inside `SettingsScreen`, which was correct while Settings was the only door
    /// to the membership sheet. Phase 108 adds a second — a locked card on Today — and two
    /// instances would be two `GET /v1/families/me` readers and two opinions about which plan is
    /// selected, which is the duplication `GuardiansSection` already warns about for the same type.
    ///
    /// Owned here for the same reason `todayModel` is: a tab switch destroys the screen, and this
    /// must outlive that.
    @State private var subscription: SubscriptionModel?
    @State private var tab: Tab = .today
    @State private var composer: ComposerRequest?
    /// An assignment the widget asked for, waiting for Today to have a board to resolve it
    /// against. Cleared whether or not it resolves — see `TodayScreen`.
    @State private var requestedAssignment: UUID?
    @State private var sync: EntrySync?
    /// One instance for the signed-in app: the sweep that uploads an avatar and the Settings read
    /// that displays one are the same object, so they cannot disagree about the cache.
    ///
    /// **Not one instance for the whole process, and the exception is deliberate.**
    /// `OnboardingSession` builds its own, because setup runs before this view exists and is the
    /// only place an avatar is produced. The two never overlap in practice — onboarding hands off
    /// to `RootView` — but they do share their two stores, which is what makes the overlap
    /// harmless: state lives in `UserDefaults` and on disk rather than in either instance. Worst
    /// case if they ever did sweep together is one extra presign and an orphaned object, which is
    /// the failure mode the commit-last ordering already accepts.
    @State private var avatarSync: AvatarSync?
    /// One personalization center for the signed-in app, so Today and the composer share a cache
    /// and a mission opened from the board renders the string already in hand.
    /// **In memory only** — see `PersonalizationCenter`, where that is the never-persisted rule.
    @State private var personalization = PersonalizationCenter()
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
    /// The membership sheet, opened from the **+** sheet's call to action (phase 147). The same
    /// `PaywallSheet` Today's locked cards, Settings and the guardian invite open — the copy file
    /// is explicit that there is one sheet and it is the same one every time.
    @State private var showingPaywall = false
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
        onSwitchChild: (() -> Void)? = nil,
        onAddChild: @escaping () -> Void = {},
        notifications: NotificationPreference,
        pendingLink: Binding<WidgetDeepLink?>
    ) {
        self.session = session
        self.childId = childId
        self.familyTimezone = familyTimezone
        self.childBirthdate = childBirthdate
        self.initialPromptSubject = promptSubject
        self.onSignOut = onSignOut
        self.onSwitchChild = onSwitchChild
        self.onAddChild = onAddChild
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
                childId: childId,
                familyTimezone: timezone,
                // **Rendered before the snapshot is written, not in the extension.** The widget
                // reads a file and does no networking, so it has no child and no environment —
                // the tokens have to be gone by the time the bytes land in the App Group. This is
                // also why a pronoun change has to republish, which it does: the subject is part
                // of the snapshot's identity, so `onChange` fires.
                subject: promptSubject
            )
        }
        // **Set here, above the sheets rather than inside the tabs, and that placement is the whole
        // reason it works** (phase 147). A sheet inherits the environment of the view its modifier
        // is attached to, so the `.environment` calls further down inside `signedIn(_:)` never
        // reach the composer — which is exactly the `{name}` defect recorded on the composer sheet
        // below. This sits above every `.sheet` and `.fullScreenCover` in this body, so the **+**
        // sheet, the composer and the backfill flow all read the same answer.
        .environment(\.mayAddMedia, mayAddMedia)
        // **The server turning a file away for membership** (phase 147). Two things happen and they
        // are different: the board is told to say one calm sentence with a way in, and it re-reads.
        //
        // The re-read is the important half. A refusal only happens when this device's picture was
        // stale — the **+** sheet offered a verb the server then declined, or a share arrived from
        // an extension that cannot know — so the answer is to go and ask the one route that knows,
        // exactly as `SubscriptionCenter.householdRevision` is answered. **Nothing here reads a
        // tier out of the 402**: the refusal is the reason to ask, not the answer.
        //
        // **Here rather than on `TodayScreen`, and that placement is the fix rather than a
        // preference.** A composer opened from the **+** button can be saved from any tab, and the
        // sweep that meets the refusal runs on its dismissal — so on Timeline or Settings the board
        // is not mounted, an `onChange` there would never fire, and re-mounting establishes at the
        // current count without firing either. The note would simply have been lost on three tabs
        // out of four. This view is alive on all of them.
        //
        // `nil → 1` must fire and `old ?? 0` is what allows it: the coordinator is nil for the first
        // frame and no refusal can predate it, so any increase is a real event.
        .onChange(of: mediaCoordinator?.membershipRefusals) { old, new in
            guard let new, new > (old ?? 0) else { return }
            todayModel.noteMediaRefusal()
            Task {
                await subscription?.refreshHousehold()
                await todayModel.load(showSpinner: false)
            }
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
            if avatarSync == nil {
                avatarSync = AvatarSync(api: session.api)
            }
            if subscription == nil { subscription = SubscriptionModel(api: session.api) }
            if sync == nil {
                sync = EntrySync(
                    api: session.api,
                    context: context,
                    media: mediaCoordinator,
                    avatars: avatarSync
                )
            }
            if shareDrain == nil {
                shareDrain = ShareDrain(context: context, childId: childId)
            }
            if backfill == nil {
                let source = PhotoLibraryBackfillSource()
                backfillSource = source
                backfill = BackfillScanner(source: source, childId: childId)
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
            // **The household is read here now, and it has to be** (phase 147, corrected Sep 6).
            // `mayAddMedia` gates the **+** sheet and every picker in the composer on this
            // document's `entitled`, and until this phase nothing above the tabs ever asked for it
            // — `SubscriptionModel.household` was populated only by opening the paywall or the
            // Settings card, so a parent who never went there would have been offered media
            // forever on the nil-fails-open rule. Awaited rather than fired and forgotten so the
            // first **+** tap of a launch reads an answer rather than the default.
            //
            // **Not a second opinion about the tier.** This is the same route, the same document
            // and the same per-session model Settings reads; `SubscriptionCenter` still refuses to
            // hold one, for the reason it gives.
            await subscription?.refreshHousehold()
            await runSweep()
            scanForBackfill()
        }
        // Entries saved while offline live in SwiftData until something re-sends them. This is
        // that something: without it, local-first saving keeps the work and never delivers it.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // **The staging sweep, which until now had never once run.** It was written,
                // tested and never called, so the disposal rule its own doc comment describes
                // had never executed and every uploaded photo's full-resolution original stayed
                // on the phone forever.
                //
                // Foreground rather than launch, and synchronous: it is a filesystem walk over a
                // directory the size of what this phone has staged, not a network call, and it
                // must not race the uploader — which is why it runs here, on the main actor,
                // where `MediaCoordinator` also lives.
                //
                // **One consequence, accepted deliberately.** Entry detail's full-resolution pass
                // reads the staged original when it is there; once the sweep removes it, that
                // pass comes over the network instead. The cached thumbnail still paints
                // instantly, so the tile is never empty — it sharpens a moment later rather than
                // immediately, which is how the fullscreen viewer has always behaved for older
                // entries.
                StagingSweeper(store: StagingStore(), context: context).sweep()
                Task { await runSweep() }
                // **The household, on every foreground** (phase 147), for the reason
                // `SubscriptionSection` re-reads on the same event: a subscription bought on
                // another device, a grant issued by an admin, a trial that ran out overnight or a
                // lapse are all answers that move while the app is away, and `mayAddMedia` is what
                // the **+** button offers on the next tap. A foreground is a reason to re-read,
                // never a transaction.
                Task { await subscription?.refreshHousehold() }
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
            // **The subject and the personalizer are re-applied here, and they have to be.**
            // `.promptSubject(_:)` is set further down, inside the tab content — and a sheet is
            // presented outside the subtree it is attached to, so the composer was getting the
            // default empty subject. `{name}` has no name to resolve to under that default and
            // renders literally, which is exactly what reached the phone: Today said "What is
            // Hendrix afraid of right now?" and the composer, quoting the same assignment, said
            // "What is {name} afraid of right now?".
            //
            // It stayed invisible until phase 24 because no seeded body contained a brace, so the
            // renderer was an identity function everywhere and a missing subject cost nothing. The
            // pronoun tokens still degrade quietly — they/them is grammatical for anyone — so
            // `{name}` was the only visible half of a gap that covers all thirteen.
            ComposerView(request: request, api: session.api)
                .promptSubject(promptSubject)
                .environment(\.personalization, personalization)
        }
        .sheet(isPresented: $showingAddSheet, onDismiss: consumePendingAdd) {
            AddToArchiveSheet(model: addToArchiveModel) { pendingAdd = $0 }
        }
        .fullScreenCover(isPresented: $showingBackfill) {
            if let backfill, let backfillSource {
                BackfillFlowView(
                    childId: childId,
                    childBirthdate: resolvedBirthdate,
                    // From the `YYYY-MM-DD` string, not from `resolvedBirthdate` — see
                    // `BackfillMonth(calendarDay:)`. The two answer differently near a month
                    // boundary for a family whose timezone is not this phone's.
                    birthMonth: BackfillMonth(calendarDay: childBirthdate),
                    familyTimezone: timezone,
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
        // **The membership sheet, opened from the + sheet** (phase 147).
        //
        // Presented here rather than from `AddToArchiveSheet`, because a sheet presented from a
        // sheet that is on its way out is dropped — the same constraint that made
        // `AddToArchiveChoice` an enum in the first place, so the call to action rides the
        // mechanism that already exists rather than a second one.
        //
        // `onDismiss` re-reads the board for the reason `TodayScreen`'s does: since phase 140 the
        // sheet dismisses itself the moment Apple takes the money, before the server has answered,
        // and this re-read is what turns `mayAddMedia` over on the tab the parent is actually on —
        // Today's own `onChange` does not run while Settings or Timeline is showing.
        .sheet(isPresented: $showingPaywall) {
            Task {
                // The household first, because it is what `mayAddMedia` reads — the board is
                // re-read beside it so the locked cards catch up in the same beat.
                await subscription?.refreshHousehold()
                await todayModel.load(showSpinner: false)
            }
        } content: {
            if let subscription {
                PaywallSheet(model: subscription) { showingPaywall = false }
            }
        }
    }

    /// **May this household put a new file in the archive?** The server's answer, read and never
    /// computed (iOS rule 1, D9).
    ///
    /// **It is `GET /v1/families/me`'s `entitled`** — the same field the API lane's phase-147 gate
    /// keys on, so this client refuses exactly what the server refuses and never a household the
    /// server would have served. It reads it off `SubscriptionModel.household`, which is the one
    /// place in this app entitled to say what the server said about the household (D5), and which
    /// is refreshed below at launch, on every foreground, and whenever the answer could have moved.
    ///
    /// **`nil` fails open**, and it means two things that are the same thing: `entitled` absent
    /// (a server older than phase 121) and the household not read yet. D9 — the device never
    /// decides entitlement, and a value it cannot read means entitled. A parent in a tunnel is
    /// offered everything, and the server's 402 is the backstop.
    ///
    /// **The board's locked cards still read `TodayResponse.access`, and that is not a second
    /// answer.** `access_for` computes `entitled = subscribed or granted or in_trial` and then
    /// `access = "subscribed" if (subscribed or granted) else ("trial" if entitled else "free")`,
    /// so `access != "free"` and `entitled` are the same boolean by construction.
    /// `MediaMembershipTests.theTwoServerAnswersCannotDisagree` is that invariant as a test, which
    /// is what keeps them from drifting now that they arrive on two different documents.
    ///
    /// **A household inside its fourteen days is entitled**, so it is offered everything — which is
    /// deliberately *not* `FamilySummary.isMember` (`receipt || grant`). See
    /// `.claude/coordination/phase-147/CONTRACT_REQUEST-ios-1300.md`.
    ///
    /// **The rule itself is in `MembershipPresentation`, not here**, so it can be asserted: this
    /// view is a surface the suite cannot render, and a decision written in a `body` is a decision
    /// nothing checks.
    private var mayAddMedia: Bool {
        MembershipPresentation.mayAddMedia(household: subscription?.household)
    }

    /// What the **+** sheet shows.
    ///
    /// **The camera-roll row is in it in every state.** It used to be conditioned on this list
    /// being non-empty, and the list is empty until a scan has produced clusters — which needs
    /// authorization, which is only ever asked for by the explainer that lives behind the row.
    /// A phone that had never granted access therefore never saw the row and never could.
    private var addToArchiveModel: AddToArchiveModel {
        guard let backfill else { return AddToArchiveModel(mayAddMedia: mayAddMedia) }
        let clusters: [BackfillCluster]
        if case .ready(let ready) = backfill.state { clusters = ready } else { clusters = [] }
        return AddToArchiveModel(
            authorization: backfill.authorization,
            clusters: clusters,
            mayAddMedia: mayAddMedia
        )
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
        case .membership:
            // Guarded at the point of opening, not inside the sheet, for the reason `TodayScreen`
            // states at its own locked card: `subscription` is nil for the first frame, and an
            // `if let` inside the content presents an **empty sheet** the parent has to dismiss.
            // Doing nothing for that fraction of a second is the better failure.
            if subscription != nil { showingPaywall = true }
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
        // **Scoped to this child, and it is not cosmetic.** One store holds every child's rows,
        // and these dates are what tells the camera-roll backfill which months already have
        // something written in them. Unscoped, a month the sibling wrote in counts as covered,
        // and this child's empty months are silently never offered — a prompt that never appears
        // is not a bug anyone can see. `let child` because `#Predicate` cannot capture `self`;
        // `TimelineModel.oldestCachedOccurredAt` uses the same shape.
        let child = childId
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.childId == child && $0.deletedAt == nil }
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
        // This child's first entry, not the device's. The re-offer is spent once and never comes
        // back, so an unscoped count hands a newly added second child an offer that was already
        // used up by their sibling's archive — on the one screen where the parent is most likely
        // to say yes.
        let child = childId
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.childId == child && $0.deletedAt == nil }
        )
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
                        onSwitchChild: onSwitchChild,
                        onSync: { await runSweep() },
                        openComposer: { composer = $0 },
                        subscription: subscription,
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
                        onAddChild: onAddChild,
                        sync: sync,
                        avatarSync: avatarSync,
                        syncEngine: syncEngine,
                        transcription: transcription,
                        notifications: notifications,
                        onTimezoneResolved: { resolvedTimezone = $0 },
                        onPromptSubjectChanged: { resolvedPromptSubject = $0 },
                        subscription: subscription
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
            // Set once, in the same place and for the same reason. One center above every tab is
            // what makes the cache shared: Today personalizes a mission, and opening the composer
            // on that same mission renders the string already in hand rather than asking again.
            .environment(\.personalization, personalization)
            // The server's number, carried rather than computed. Nil until `GET /children` lands,
            // which the model is simply told nothing about.
            .environment(\.childAgeMonths, childAgeMonths)
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
        guard let newest = ExtractionQueue.pending(in: context, childId: childId)
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

