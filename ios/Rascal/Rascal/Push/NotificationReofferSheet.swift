import SwiftUI

/// The one re-offer, after the first completed entry.
///
/// **Offered exactly once, ever.** The parent said "Not now" during setup, before they had any
/// idea what the app did. They have now finished an entry, so the offer means something it could
/// not have meant on day zero — and that is the whole justification for asking twice. A third ask
/// would be nagging, so `markReofferShown` spends it the moment this appears rather than when it
/// is answered: a parent who swipes it away has answered.
///
/// Never shown after a system-level denial. `shouldReofferAfterFirstEntry` is false in that case
/// and there is no route to this view that does not go through it.
struct NotificationReofferSheet: View {
    @Bindable var preference: NotificationPreference
    let familyTimezone: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Want a note when the next one's ready?")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("One a day, carrying that day's mission. Never more than one, and off whenever you want.")
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(timeLine)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Button("Turn it on") {
                    Task {
                        await preference.setEnabled(true)
                        dismiss()
                    }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(preference.isWorking)

                // Equal weight, and it is the end of the matter. Nothing records this as a
                // deferral to be revisited — there is no third ask.
                OnboardingSecondaryButton(title: "No thanks") { dismiss() }
                    .disabled(preference.isWorking)
            }
        }
        .padding(Layout.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.canvas)
    }

    private var timeLine: String {
        let at = preference.notifyTime.formatted()
        guard let familyTimezone else { return "We'd send it at \(at)." }
        return "We'd send it at \(at), in \(familyTimezone)."
    }
}
