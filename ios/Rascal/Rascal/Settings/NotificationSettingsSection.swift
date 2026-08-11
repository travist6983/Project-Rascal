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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader("Daily note")

            SettingsCard {
                switch preference.offer {
                case .blockedBySystem:
                    blocked
                case .mayAsk, .alreadyAuthorized:
                    available
                }
            }
        }
    }

    // MARK: Available

    @ViewBuilder
    private var available: some View {
        NotificationToggleRow(
            label: "One note a day",
            detail: "It carries that day's mission. Never more than one.",
            isOn: preference.notifyEnabled,
            isEnabled: !preference.isWorking
        ) { wanted in
            Task { await preference.setEnabled(wanted) }
        }

        // The time only matters when something is being sent. Showing a picker under an off
        // toggle invites a parent to set a time for a notification that will not arrive.
        if preference.notifyEnabled {
            SettingsDivider()
            SettingsRow(
                label: "Sent at",
                value: preference.notifyTime.formatted()
            ) {
                showingPicker = true
            }

            if let familyTimezone {
                SettingsDivider()
                SettingsValueRow(label: "In", value: familyTimezone)
            }
        }
    }

    // MARK: Refused at the system level — terminal

    private var blocked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notifications are off for Rascal in iOS Settings.")
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            // Says where it is and stops. No pitch for what they are missing, no second ask, and
            // no count of anything. A refusal is a complete answer and the app behaves
            // identically without it.
            Text("If you want it back, it's in Settings → Rascal → Notifications.")
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
