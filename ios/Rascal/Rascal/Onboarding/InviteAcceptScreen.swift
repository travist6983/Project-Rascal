import SwiftUI

/// What somebody sees when they tap an invitation link.
///
/// Presented over whatever the gate is showing, because it has to work in **both** session
/// states: signed out, where the preview is all there is until they sign in, and signed in,
/// where the whole thing is two taps. A screen that only existed inside one of those would be
/// unreachable for exactly the person it was built for.
struct InviteAcceptScreen: View {
    @Bindable var model: InviteAcceptModel
    let isSignedIn: Bool
    /// Hands off to the gate's own sign-in path rather than starting a parallel one.
    var onSignIn: () -> Void
    var onDone: () -> Void

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                switch model.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Opening the invitation")

                case .preview(let preview, let canAccept):
                    previewBody(preview, canAccept: canAccept)

                case .noLongerValid:
                    // One sentence for four server states, because the server answers one 404
                    // for all of them on purpose — telling them apart would say whether a token
                    // ever existed.
                    message(
                        title: "This invitation is no longer good",
                        body: "It may have already been used, or it may have expired. "
                            + "Ask them to send you a new one — it only takes a moment.",
                        action: "Close"
                    )

                case .joined(let childCount):
                    message(
                        title: "You're in",
                        body: childCount == 1
                            ? "You and the other parent now share the same archive. "
                                + "It will fill in here in a moment."
                            : "You and the other parent now share the same archive, "
                                + "for all \(childCount) of them. It will fill in here in a moment.",
                        action: "Start"
                    )

                case .refused(let text):
                    message(title: "Not this time", body: text, action: "Close")

                case .unreachable(let text):
                    unreachableBody(text)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await model.load(isSignedIn: isSignedIn) }
    }

    @ViewBuilder
    private func previewBody(_ preview: InvitePreview, canAccept: Bool) -> some View {
        Text(headline(preview))
            .typeRole(.title)
            .foregroundStyle(Color.ink)

        if !preview.children.isEmpty {
            Text(childrenSentence(preview.children))
                .typeRole(.body)
                .foregroundStyle(Color.ink)
        }

        Text(
            "You'll both see the same timeline and the same moments, "
                + "and each of you gets your own prompts every day."
        )
        .typeRole(.body)
        .foregroundStyle(Color.inkMuted)

        Spacer(minLength: 0)

        if canAccept {
            Button("Join") { Task { await model.accept() } }
                .buttonStyle(PrimaryButtonStyle())
        } else {
            // **The existing sign-in path, not a parallel one.** Dismissing hands the link back
            // to the gate, which holds it across the welcome screen and re-presents this once
            // there is a session — so the token survives sign-in without a second auth flow.
            Button("Sign in to join", action: onSignIn)
                .buttonStyle(PrimaryButtonStyle())
            Text("You'll come straight back here.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }

        Button("Not now", action: onDone)
            .typeRole(.body)
            .foregroundStyle(Color.inkMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func unreachableBody(_ text: String) -> some View {
        Text("Can't reach the archive")
            .typeRole(.title)
            .foregroundStyle(Color.ink)
        Text(text)
            .typeRole(.body)
            .foregroundStyle(Color.ink)

        Spacer(minLength: 0)

        // The only state with a retry: the only one where the identical request could plausibly
        // succeed. Offering one on an expired invitation would be a button that cannot work.
        Button("Try again") { Task { await model.load(isSignedIn: isSignedIn) } }
            .buttonStyle(PrimaryButtonStyle())
        Button("Not now", action: onDone)
            .typeRole(.body)
            .foregroundStyle(Color.inkMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func message(title: String, body: String, action: String) -> some View {
        Text(title)
            .typeRole(.title)
            .foregroundStyle(Color.ink)
        Text(body)
            .typeRole(.body)
            .foregroundStyle(Color.ink)

        Spacer(minLength: 0)

        Button(action, action: onDone)
            .buttonStyle(PrimaryButtonStyle())
    }

    /// Names the person if the server knew one. It often will not — a parent who signed in
    /// through Apple's private relay and skipped onboarding has never told us a name — and
    /// "Someone" is honest where a placeholder would be a small lie about who is asking.
    private func headline(_ preview: InvitePreview) -> String {
        if let name = preview.invitedBy, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(name) wants to share their archive with you"
        }
        return "Someone wants to share their archive with you"
    }

    /// First names only, which is all the server sends. An invitation that named nobody would be
    /// impossible to recognise as yours; one that named more would be worth harvesting.
    private func childrenSentence(_ names: [String]) -> String {
        switch names.count {
        case 1: "It's the record they're keeping of \(names[0])."
        case 2: "It's the record they're keeping of \(names[0]) and \(names[1])."
        default:
            "It's the record they're keeping of "
                + names.dropLast().joined(separator: ", ")
                + ", and \(names[names.count - 1])."
        }
    }
}

#if DEBUG
/// The states, at the size the copy actually breaks at.
///
/// **Every failure state gets a preview, not just the happy one.** These are the screens
/// somebody reads when a link did not work, they are the longest sentences in the flow, and they
/// are the ones nobody looks at in the canvas because the happy path is what gets built.
private func _previewModel(_ state: InviteAcceptModel.State) -> InviteAcceptModel {
    InviteAcceptModel(previewing: state)
}

private let _preview = InvitePreview(
    invitedBy: "Travis",
    role: "parent",
    expiresAt: .now.addingTimeInterval(7 * 86_400),
    children: ["Miles", "Nora"]
)

#Preview("Invite — preview, signed out") {
    InviteAcceptScreen(
        model: _previewModel(.preview(_preview, canAccept: false)),
        isSignedIn: false, onSignIn: {}, onDone: {}
    )
}

#Preview("Invite — preview, signed in") {
    InviteAcceptScreen(
        model: _previewModel(.preview(_preview, canAccept: true)),
        isSignedIn: true, onSignIn: {}, onDone: {}
    )
}

#Preview("Invite — no longer valid") {
    InviteAcceptScreen(
        model: _previewModel(.noLongerValid), isSignedIn: false, onSignIn: {}, onDone: {}
    )
}

#Preview("Invite — joined") {
    InviteAcceptScreen(
        model: _previewModel(.joined(childCount: 2)),
        isSignedIn: true, onSignIn: {}, onDone: {}
    )
}

#Preview("Invite — household full") {
    InviteAcceptScreen(
        model: _previewModel(.refused("This household already has two parents.")),
        isSignedIn: true, onSignIn: {}, onDone: {}
    )
}

#Preview("Invite — unreachable") {
    InviteAcceptScreen(
        model: _previewModel(.unreachable("No connection. Saved here, and it'll sync when you're back.")),
        isSignedIn: true, onSignIn: {}, onDone: {}
    )
}

#Preview("Invite — preview, AX XXL") {
    InviteAcceptScreen(
        model: _previewModel(.preview(_preview, canAccept: false)),
        isSignedIn: false, onSignIn: {}, onDone: {}
    )
    .environment(\.dynamicTypeSize, .accessibility4)
}

#Preview("Invite — no longer valid, AX XXL") {
    InviteAcceptScreen(
        model: _previewModel(.noLongerValid), isSignedIn: false, onSignIn: {}, onDone: {}
    )
    .environment(\.dynamicTypeSize, .accessibility4)
}

#Preview("Invite — joined, AX XXL") {
    InviteAcceptScreen(
        model: _previewModel(.joined(childCount: 2)),
        isSignedIn: true, onSignIn: {}, onDone: {}
    )
    .environment(\.dynamicTypeSize, .accessibility4)
}

#Preview("Upgrade sheet") {
    PaywallSheet(model: SubscriptionModel(previewing: .loading)) {}
}

#Preview("Upgrade sheet — AX XXL") {
    PaywallSheet(model: SubscriptionModel(previewing: .loading)) {}
        .environment(\.dynamicTypeSize, .accessibility4)
}
#endif
