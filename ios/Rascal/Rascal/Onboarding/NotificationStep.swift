import SwiftUI

/// The last step of setup, and the only one that spends something it cannot get back.
///
/// **This screen is the soft ask.** iOS shows its permission prompt once per install, so firing
/// it at someone who has not already decided is how a "not right now" becomes a permanent no.
/// The parent answers here first; only "Turn it on" reaches the system.
///
/// The two actions carry equal visual weight and equal VoiceOver treatment. Neither is styled as
/// the default, neither is a `PrimaryButtonStyle` while the other is a link, and there is no
/// urgency copy, no count of what they would miss, and nothing that reads as a consequence for
/// choosing "Not now" — which is a complete answer, not a deferral to be recovered from.
struct NotificationStep: View {
    @Bindable var session: OnboardingSession

    /// Local until it is sent. Mirrored into the draft on change so a kill mid-step resumes with
    /// the same time on the wheel.
    @State private var time: NotifyTime = .default
    @State private var showingPicker = false

    private var name: String {
        let trimmed = session.draft.trimmedName
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    var body: some View {
        OnboardingStepScaffold(
            title: "One note a day?",
            subtitle: "It carries that day's mission. That's the whole of it."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("We'll send it at \(time.formatted()).")
                        .typeRole(.cardTitle)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    // **Says which clock this is.** A parent travelling without this line thinks
                    // the feature broke; the server resolves the time in the child's zone and
                    // never in the device's, so the screen has to say so where they can see it.
                    Text("In \(session.draft.timezone) — \(name)'s time, not this phone's.")
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                .accessibilityElement(children: .combine)

                // Inline, on this screen. A second screen for a time picker would make a
                // one-decision step into two.
                Button("Change the time") { showingPicker = true }
                    .typeRole(.body)
                    .foregroundStyle(Color.terracotta)
                    .accessibilityHint("Pick a different time of day")

                Text("Never more than one. Off whenever you want, in Settings.")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            VStack(spacing: 6) {
                if let notice = session.notice {
                    OnboardingNotice(message: notice) {
                        Task { await session.finishSetup() }
                    }
                    .padding(.bottom, 6)
                }

                Button("Turn it on") {
                    Task { await session.acceptNotifications(at: time) }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(session.isWorking)

                // Same size, same hit area, same prominence in the reading order. The only
                // difference is that this one does not fire the system prompt.
                OnboardingSecondaryButton(title: "Not now") {
                    Task { await session.declineNotifications() }
                }
                .disabled(session.isWorking)
            }
        }
        .sheet(isPresented: $showingPicker) {
            NotifyTimePickerSheet(selection: $time)
        }
        .task {
            if let stored = session.draft.notifyTime { time = stored }
        }
        .onChange(of: time) { _, value in
            session.draft.notifyTime = value
            session.persist()
        }
    }
}

// MARK: - The time picker

/// A wheel over hour and minute, in the device's locale, presented as a sheet.
///
/// Deliberately **not** a `DatePicker` bound to a `Date`. A `Date` carries a timezone, and this
/// value is a wall-clock time the server resolves somewhere else entirely — binding one to the
/// other is how the client ends up deciding what "seven in the evening" meant.
struct NotifyTimePickerSheet: View {
    @Binding var selection: NotifyTime
    @Environment(\.dismiss) private var dismiss

    @State private var hour: Int = 19
    @State private var minute: Int = 0

    /// Five-minute steps. A daily notification does not need 07:43, and sixty rows per wheel is
    /// a worse thing to spin past than twelve.
    private static let minutes = Array(stride(from: 0, to: 60, by: 5))

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 0) {
                    Picker("Hour", selection: $hour) {
                        ForEach(0..<24, id: \.self) { value in
                            Text(NotifyTime(hour: value, minute: 0).formatted())
                                .tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityLabel("Hour")

                    Picker("Minutes", selection: $minute) {
                        ForEach(Self.minutes, id: \.self) { value in
                            Text(String(format: ":%02d", value)).tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityLabel("Minutes")
                }
                .frame(maxHeight: 200)

                Spacer(minLength: 0)
            }
            .padding(Layout.screenMargin)
            .background(Color.canvas)
            .navigationTitle("When?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selection = NotifyTime(hour: hour, minute: minute)
                        dismiss()
                    }
                }
            }
        }
        .task {
            hour = selection.hour
            // The stored value may not sit on a five-minute boundary — a previous build, or a
            // preference set from somewhere else. Snap to the nearest row rather than showing a
            // wheel whose selection is not on it.
            minute = Self.minutes.min(by: {
                abs($0 - selection.minute) < abs($1 - selection.minute)
            }) ?? 0
        }
    }
}
