import SwiftData
import SwiftUI

struct RootView: View {
    @State private var session = AppSession.live()
    @State private var tab: Tab = .today
    @State private var composer: ComposerRequest?
    @State private var sync: EntrySync?
    @State private var mediaCoordinator: MediaCoordinator?
    @State private var unsynced = 0

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
            case .failed(let message):
                SignInFailedView(message: message) {
                    Task { await session.signOutAndRetry() }
                }
            }
        }
        .task {
            await session.start()
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
            if sync == nil {
                sync = EntrySync(api: session.api, context: context, media: mediaCoordinator)
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
                        unsyncedCount: unsynced,
                        onRetrySync: { Task { await runSweep() } }
                    ) { composer = $0 }
                case .timeline, .moments, .settings:
                    PlaceholderScreen(tab: tab)
                case .create:
                    PlaceholderScreen(tab: .today)
                }
            }
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
    /// Push anything still local, then refresh the count the Today screen shows.
    private func runSweep() async {
        guard let sync else { return }
        await sync.sweep()
        unsynced = sync.unsyncedCount()
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
