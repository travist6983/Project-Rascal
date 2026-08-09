import SwiftData
import SwiftUI

struct RootView: View {
    @State private var session = AppSession.live()
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

            switch session.phase {
            case .launching:
                LaunchView()
            case .signedIn(let childId):
                signedIn(childId: childId)
            case .signedOut:
                SignedOutView { Task { await session.signIn() } }
            case .failed(let message):
                SignInFailedView(message: message) {
                    Task { await session.signOutAndRetry() }
                }
            }
        }
        .task {
            await session.start()
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
            // The engine needs the child, so it cannot be built until the session resolves one.
            if syncEngine == nil, case .signedIn(let childId) = session.phase {
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

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.terracotta)
            Text("Opening the archive")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
        }
    }
}

/// After a deliberate sign-out. Nothing went wrong, so nothing here says anything did — and
/// nothing signs back in until someone asks it to.
private struct SignedOutView: View {
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text("Signed out")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text("The archive is safe. Sign in to open it again.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button("Sign in", action: signIn)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Layout.screenMargin * 2)
    }
}

/// Says what happened and what to do, in the interface's voice. It does not apologise and it
/// is not vague — `docs/design-system.md`, copy rules.
private struct SignInFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text("Can't open the archive")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text(message)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Layout.screenMargin * 2)
    }
}
