import SwiftUI

/// The words, separated from the view so they can be asserted.
///
/// **They were inline until a break-test showed nothing could catch them being wrong.** Making
/// the sheet always claim the archive would be deleted — the frightening lie, in the exact case
/// where a second parent keeps it — compiled cleanly and passed every test. Copy that decides
/// whether a sentence is true belongs somewhere a test can read it.
nonisolated enum DeleteAccountCopy {

    /// What actually happens, in the order somebody needs to hear it.
    ///
    /// The two shapes differ in the only way that matters: with another parent in the household
    /// the children and everything written about them **stay**, and what goes is the leaver's
    /// way in. Saying otherwise would frighten somebody about a loss that is not happening.
    static func consequences(hasOtherGuardian: Bool) -> [String] {
        var lines = ["You'll be signed out of every device straight away."]
        if hasOtherGuardian {
            lines.append(
                "The children and everything written about them stay with the other parent."
            )
            lines.append("What goes is your way in: your sign-in methods and your access.")
        } else {
            lines.append(
                "After seven days the children, the entries, the photos and the recordings "
                    + "are deleted."
            )
            lines.append("This cannot be undone once it happens.")
        }
        lines.append("Signing in again before then cancels it, and nothing is lost.")
        return lines
    }

    /// The second tap's message, in the system dialog.
    static func confirmation(hasOtherGuardian: Bool) -> String {
        hasOtherGuardian
            ? "You have seven days to change your mind. The archive stays with the other parent."
            : "You have seven days to change your mind. After that the archive is gone for good."
    }
}

/// The last thing somebody reads before an irreversible choice, so it says exactly what happens.
///
/// **It states what survives, not only what goes.** If another parent shares the household, the
/// children and everything written about them stay with them — a screen that said "everything
/// will be deleted" would be frightening and, in that case, false.
///
/// **No red anywhere on this screen**, per `docs/design-system.md`: there is no destructive
/// colour in this product, and weight comes from placement rather than hue. The one exception the
/// design system allows is what iOS paints for `role: .destructive` in a system confirmation
/// dialog, which is the second tap and not this one.
struct DeleteAccountSheet: View {
    @Bindable var model: AccountDeletionModel
    /// Whether a second parent shares this household, which changes what actually happens.
    let hasOtherGuardian: Bool
    var onDeleted: () -> Void
    var onDismiss: () -> Void

    @State private var confirming = false

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.state {
                    case .scheduled(let executeAfter):
                        scheduled(executeAfter)
                    default:
                        explanation
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            // The one place red is allowed in this product, and it is the system's red rather
            // than one we drew.
            Button("Delete my account", role: .destructive) {
                Task { await model.request() }
            }
            Button("Keep my account", role: .cancel) {}
        } message: {
            Text(DeleteAccountCopy.confirmation(hasOtherGuardian: hasOtherGuardian))
        }
    }

    @ViewBuilder
    private var explanation: some View {
        Text("Delete your account")
            .typeRole(.title)
            .foregroundStyle(Color.ink)

        Text("Nothing happens for seven days. Until then you can undo this by signing back in.")
            .typeRole(.body)
            .foregroundStyle(Color.ink)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(
                DeleteAccountCopy.consequences(hasOtherGuardian: hasOtherGuardian), id: \.self
            ) { text in
                line(text)
            }
        }

        if case .failed(let message) = model.state {
            Text(message)
                .typeRole(.metadata)
                .foregroundStyle(Color.ink)
        }

        Spacer(minLength: 8)

        Button("Delete my account") { confirming = true }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.state == .working)

        Button("Not now", action: onDismiss)
            .typeRole(.body)
            .foregroundStyle(Color.inkMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// After the request. **The date comes from the server**, so this never paraphrases a policy
    /// it would then have to keep in step with.
    @ViewBuilder
    private func scheduled(_ executeAfter: Date) -> some View {
        Text("Your account will be deleted")
            .typeRole(.title)
            .foregroundStyle(Color.ink)

        Text("On \(DayHeaderText.dayAndMonth(executeAfter)). You're signed out now.")
            .typeRole(.body)
            .foregroundStyle(Color.ink)

        Text("If you change your mind, sign in again before then and nothing will have happened.")
            .typeRole(.body)
            .foregroundStyle(Color.inkMuted)

        Spacer(minLength: 8)

        Button("Done", action: onDeleted)
            .buttonStyle(PrimaryButtonStyle())
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
            Text(text)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
        }
    }
}

#if DEBUG
#Preview("Delete — sole parent") {
    DeleteAccountSheet(
        model: AccountDeletionModel(previewing: .idle),
        hasOtherGuardian: false, onDeleted: {}, onDismiss: {}
    )
}

#Preview("Delete — household of two") {
    DeleteAccountSheet(
        model: AccountDeletionModel(previewing: .idle),
        hasOtherGuardian: true, onDeleted: {}, onDismiss: {}
    )
}

#Preview("Delete — scheduled") {
    DeleteAccountSheet(
        model: AccountDeletionModel(
            previewing: .scheduled(executeAfter: .now.addingTimeInterval(7 * 86_400))
        ),
        hasOtherGuardian: false, onDeleted: {}, onDismiss: {}
    )
}

#Preview("Delete — sole parent, AX XXL") {
    DeleteAccountSheet(
        model: AccountDeletionModel(previewing: .idle),
        hasOtherGuardian: false, onDeleted: {}, onDismiss: {}
    )
    .environment(\.dynamicTypeSize, .accessibility4)
}

#Preview("Delete — scheduled, AX XXL") {
    DeleteAccountSheet(
        model: AccountDeletionModel(
            previewing: .scheduled(executeAfter: .now.addingTimeInterval(7 * 86_400))
        ),
        hasOtherGuardian: false, onDeleted: {}, onDismiss: {}
    )
    .environment(\.dynamicTypeSize, .accessibility4)
}
#endif
