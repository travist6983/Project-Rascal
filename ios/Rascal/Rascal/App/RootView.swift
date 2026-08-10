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
    /// Handed down to Settings. The gate owns signing out, because it is the only thing that can
    /// put the app back on the welcome screen afterwards.
    let onSignOut: () async -> Void
    @State private var tab: Tab = .today
    @State private var composer: ComposerRequest?
    @State private var sync: EntrySync?
    @State private var syncEngine: SyncEngine?
    @State private var mediaCoordinator: MediaCoordinator?
    /// One transcriber for the process, for the same reason there is one upload coordinator:
    /// **no parallel inference.** Two queues would mean two `SpeechAnalyzer`s warming the phone
    /// at once, which is a real cost on a device someone is holding.
    @State private var transcription: TranscriptionQueue?
    /// One picture cache for the whole app, so the timeline, Moments, and a detail screen all
    /// draw from the same fetches rather than each pulling the same photo down again.
    @State private var thumbnails: ThumbnailStore?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            signedIn(childId: childId)
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
        }
        // Entries saved while offline live in SwiftData until something re-sends them. This is
        // that something: without it, local-first saving keeps the work and never delivers it.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await runSweep() } }
        }
        .sheet(item: $composer, onDismiss: { Task { await runSweep() } }) { request in
            ComposerView(request: request, api: session.api)
        }
    }

    private func signedIn(childId: UUID) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .today:
                    TodayScreen(
                        childId: childId,
                        api: session.api,
                        onRetrySync: { Task { await runSweep() } },
                        onSync: { await runSweep() }
                    ) { composer = $0 }
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
                        transcription: transcription
                    )
                case .create:
                    // The centre button opens the composer as a sheet and never selects a tab,
                    // so this is unreachable. Today is what the app falls back to rather than a
                    // blank screen, on the principle that a fallback should be somewhere real.
                    TodayScreen(childId: childId, api: session.api) { composer = $0 }
                }
            }
            .environment(\.thumbnails, thumbnails)
            // Clear the floating bar so the last card is never trapped underneath it.
            .safeAreaPadding(.bottom, 84)

            FloatingTabBar(selection: $tab) {
                composer = ComposerRequest(childId: childId, assignment: nil, mode: .text)
            }
            .padding(.bottom, 4)
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
    private func runSweep() async {
        if let syncEngine {
            await syncEngine.pull()
        } else {
            await sync?.sweep()
        }
    }
}

