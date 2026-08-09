import SwiftUI

/// The sync-pull controls, inside the existing sync-status section.
///
/// **This is a switch for something unverified, and it says so in words.** Everything else in
/// Settings reports on a path that has been used; this one gates a path that has not, and the
/// honest thing is one plain line saying that rather than a toggle that looks like every other
/// toggle. There is still nothing red here — an unverified feature is not an emergency.
///
/// The order is the order it gets used in: read the position, run the dry run, read the report,
/// then flip the switch. Reset is last and behind a confirmation, where irreversible-feeling
/// things live on this screen.
struct SyncPullSection: View {
    let model: SyncStatusModel

    @State private var confirmingReset = false
    @State private var showingReport = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsDivider()
            SettingsValueRow(label: "Last pull", value: model.lastPullDescription)
            if let cursor = model.cursorDescription {
                SettingsDivider()
                SettingsValueRow(label: "Position", value: cursor)
            }
            if let error = model.lastErrorDescription {
                SettingsDivider()
                // Reported, not alarmed about. A failed sync is a fact about the network, and
                // this is the only screen in the app that mentions it at all.
                SettingsValueRow(label: "Last attempt", value: error)
            }

            SettingsDivider()
            toggleRow

            SettingsDivider()
            dryRunRow

            SettingsDivider()
            SettingsActionRow(
                label: "Reset sync position",
                detail: "Forgets where syncing got to, so the next one reads the whole archive again. Nothing is deleted.",
                isEnabled: !model.isBusy
            ) { confirmingReset = true }
        }
        .confirmationDialog(
            "Reset the sync position?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset") { model.resetCursor() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next sync reads your whole archive from the beginning. It takes longer and changes nothing that is already here.")
        }
        .sheet(isPresented: $showingReport) {
            SyncReportSheet(title: model.reportTitle, report: model.report ?? "")
        }
    }

    /// The switch itself.
    ///
    /// A plain `Toggle`, tinted terracotta, with the caveat underneath it rather than hidden in a
    /// help sheet. Someone turning this on should read why they might not want to in the same
    /// glance in which they turn it on.
    private var toggleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: model.pullEnabledBinding) {
                Text("Pull changes from the server")
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
            }
            .tint(.terracotta)
            Text("New, and not yet verified against a real archive. Run the dry run first and read what it would change.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Layout.cardPadding)
    }

    @ViewBuilder
    private var dryRunRow: some View {
        switch model.dryRun {
        case .idle, .running:
            SettingsActionRow(
                label: "Run a dry run",
                detail: "Asks the server what changed and works out exactly what it would insert, update, and remove here — without changing anything.",
                isBusy: model.dryRun == .running
            ) { Task { await model.runDryRun() } }

        case .ready(let summary):
            VStack(alignment: .leading, spacing: 10) {
                Text(summary)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("Read the report") { showingReport = true }
                        .typeRole(.body)
                        .foregroundStyle(Color.terracotta)
                    Button("Run it again") { Task { await model.runDryRun() } }
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            .padding(Layout.cardPadding)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("The dry run didn't finish")
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                Text(message)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.runDryRun() } }
                    .typeRole(.body)
                    .foregroundStyle(Color.terracotta)
            }
            .padding(Layout.cardPadding)
        }
    }
}

/// The report, full width and monospaced, with one button that copies the whole thing.
///
/// Monospaced because the counts table is aligned in columns and a proportional face would turn
/// it into a smear. It scrolls in both directions on purpose — the deletion list carries full
/// UUIDs, and wrapping them would make the one section that must be read line by line unreadable.
struct SyncReportSheet: View {
    let title: String
    let report: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(report)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .padding(Layout.screenMargin)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.inkMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                    .foregroundStyle(Color.terracotta)
                }
            }
        }
    }
}
