import SwiftData
import SwiftUI

struct RootView: View {
    @State private var session = AppSession.live()
    @State private var tab: Tab = .today
    @State private var composer: ComposerRequest?

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
        .task { await session.start() }
        .sheet(item: $composer) { request in
            ComposerView(request: request, api: session.api)
        }
    }

    private func signedIn(childId: UUID) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .today:
                    TodayScreen(childId: childId, api: session.api) { composer = $0 }
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
