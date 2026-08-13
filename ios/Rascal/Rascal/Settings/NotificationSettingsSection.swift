import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The daily note, in Settings.
///
/// Added to Settings v2 rather than restructuring it: one section, built from the same
/// `SettingsCard` / `SettingsRow` vocabulary as everything above it.
///
/// **The denied state is the reason this is its own view.** A toggle that renders as available
/// after the parent has refused at the system level is a control that lies — it moves, writes a
/// preference, and no notification ever arrives. So a refusal replaces the control with a
/// sentence, and nothing on this screen asks again by any route.
struct NotificationSettingsSection: View {
    @Bindable var preference: NotificationPreference
    /// The child's `family_timezone`. Named on screen because the server resolves the send time
    /// in it and never in the device's — a travelling parent otherwise reads a correct feature as
    /// a broken one.
    let familyTimezone: String?

    @State private var showingPicker = false
    /// The sheet's working value. Seeded from the preference when the sheet opens and written
    /// back through `setTime`, which is optimistic and rolls back on a refused write.
    ///
    /// A local copy rather than a binding into the model: `notifyTime` is `private(set)` on
    /// purpose, because the only way it may change is a `PATCH /v1/me` — a two-way binding would
    /// let the row show a time the server never accepted.
    @State private var pickedTime: NotifyTime = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // **"Daily reminder", not "Daily note".** The old label described the product
            // principle and never named the mechanism, so a parent could turn on push
            // notifications without knowing that was what they were doing — which is what
            // happened. Nothing about the guarantee changed; it is just no longer a secret that
            // the thing making the guarantee is a notification.
            SettingsSectionHeader("Daily reminder")

            SettingsCard {
                switch preference.offer {
                case .blockedBySystem:
                    blocked
                case .mayAsk, .alreadyAuthorized:
                    available
                }
            }
        }
        // **The same sheet onboarding uses**, rather than a second one. Two pickers for one value
        // is two places for the five-minute step and the wheel's wording to drift apart.
        .sheet(isPresented: $showingPicker) {
            NotifyTimePickerSheet(selection: $pickedTime)
        }
        .onChange(of: pickedTime) { _, picked in
            guard picked != preference.notifyTime else { return }
            Task { await preference.setTime(picked) }
        }
    }

    // MARK: Available

    @ViewBuilder
    private var available: some View {
        NotificationToggleRow(
            label: "Daily reminder",
            detail: preference.notifyEnabled ? onDetailText : offDetailText,
            isOn: preference.notifyEnabled,
            isEnabled: !preference.isWorking
        ) { wanted in
            Task { await preference.setEnabled(wanted) }
        }

        // The time only matters when something is being sent. Showing a picker under an off
        // toggle invites a parent to set a time for a notification that will not arrive — the
        // off state names the time in words instead.
        if preference.notifyEnabled {
            SettingsDivider()
            // **The zone is inline metadata here, and the `In` row it replaces is gone.**
            // Choosing the timezone twice — once here, once in the archive section — invited the
            // two to disagree, and only one of them is the one the server reads. It is still
            // *shown*, because a time with no zone attached is exactly the ambiguity this project
            // refuses everywhere else. Displayed, not picked.
            SettingsRow(label: "Sent at", value: Self.sentAt(preference.notifyTime, in: familyTimezone)) {
                // Seeded at the moment of opening, so the wheel starts on what is actually set
                // rather than on whatever the last visit left behind.
                pickedTime = preference.notifyTime
                showingPicker = true
            }
        }

        if let failure = preference.writeFailure {
            Text(failureLine(failure))
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.cardPadding)
                .padding(.bottom, Layout.cardPadding)
        }
    }

    /// **Names the control that was refused, and the value that survived.**
    ///
    /// A single "that didn't save" line after a *toggle* failure that then quotes the send time
    /// points at the one value nobody was changing.
    func failureLine(_ failure: NotificationPreference.WriteFailure) -> String {
        switch failure {
        case .time:
            return "That didn't save — it's still set to "
                + "\(Self.sentAt(preference.notifyTime, in: familyTimezone)). "
                + "Worth trying again in a moment."
        case .switching:
            return preference.notifyEnabled
                ? "That didn't save — the daily reminder is still on. Worth trying again in a moment."
                : "That didn't save — the daily reminder is still off. Worth trying again in a moment."
        }
    }

    /// What the reminder is, and the promise it keeps.
    ///
    /// Names the mechanism — a notification — and then states the guarantee, because the second
    /// clause is true and worth saying: a finished day is silent, and the notification carries the
    /// mission and never the archive.
    var onDetailText: String {
        "A notification once a day, carrying that day's mission. One, always — never a nudge about something you missed."
    }

    /// **The off state is an available thing, not a disabled one.**
    ///
    /// Nothing dims: the same `ink` label and the same `inkMuted` line as the on state, on the
    /// same undimmed card. What changes is that the sentence says what turning it on would do,
    /// and names the time it would arrive — otherwise "off" is a fact with nothing attached to it.
    var offDetailText: String {
        "Turn it on and one notification arrives each day at \(Self.sentAt(preference.notifyTime, in: familyTimezone)), carrying that day's mission. Never more than one."
    }

    /// "7:00 PM · America/Detroit" — the time, and the zone it means.
    static func sentAt(_ time: NotifyTime, in timezone: String?) -> String {
        guard let timezone, !timezone.isEmpty else { return time.formatted() }
        return "\(time.formatted()) · \(timezone)"
    }

    // MARK: Refused at the system level — terminal

    private var blocked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notifications are off for Dogear in iOS Settings.")
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            // Says where it is and stops. No pitch for what they are missing, no second ask, and
            // no count of anything. A refusal is a complete answer and the app behaves
            // identically without it.
            Text("If you want it back, it's in Settings → Dogear → Notifications.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            #if canImport(UIKit)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .typeRole(.body)
            .foregroundStyle(Color.terracotta)
            .accessibilityHint("Opens the iOS Settings app")
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.cardPadding)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - The toggle row

/// Label, one quiet line of detail, and a switch.
///
/// Not `SettingsRow` — that one is a button with a chevron, and a switch is neither. The padding,
/// type roles and colours are the same so it reads as part of the same list.
struct NotificationToggleRow: View {
    let label: String
    var detail: String?
    let isOn: Bool
    var isEnabled: Bool = true
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                if let detail {
                    Text(detail)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            // Bound through a closure rather than a `Binding` into the model, because the write
            // is asynchronous and can be refused — `setEnabled` returns without changing anything
            // when the system has said no. A two-way binding would let the switch animate to a
            // state the model never reached.
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .tint(.terracotta)
                .disabled(!isEnabled)
        }
        .padding(Layout.cardPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(label). \($0)" } ?? label)
    }
}
