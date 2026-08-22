import SwiftUI

/// Where the pull has got to, and the switch that turns it on. Inside the sync card.
///
/// **This is a switch for something unverified, and it says so in words.** Everything else in
/// Settings reports on a path that has been used; this one gates a path that has not, and the
/// honest thing is one plain line saying that rather than a toggle that looks like every other
/// toggle. There is still nothing red here — an unverified feature is not an emergency.
///
/// The order is the order it gets used in, and the design import did not change it: read the
/// position here, run the dry run in `SyncAdvancedSection` below, read the report, come back and
/// flip the switch. The two halves are now two cards rather than one run of rows — see
/// `SyncAdvancedSection` for why — and the switch stayed with the status it is a switch *for*,
/// so the sequence still reads top to bottom and nothing gained a tap.
struct SyncPullSection: View {
    let model: SyncStatusModel

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
        }
    }

    /// The switch itself.
    ///
    /// A plain `Toggle`, tinted terracotta, with the caveat underneath it rather than hidden in a
    /// help sheet. Someone turning this on should read why they might not want to in the same
    /// glance in which they turn it on.
    ///
    /// The import draws a hand-built 50×30 pill here. It is not adopted: a stock `Toggle` already
    /// announces its state to VoiceOver, works under Switch Control and Full Keyboard Access, and
    /// grows with Dynamic Type — none of which a styled `HStack` gets for free. The tint is the
    /// one thing the import asks for that a stock toggle can honour, and it already did.
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
}

/// The dry run and the reset, in their own card under an `Advanced` label.
///
/// The design import groups these two with **recompute-ages** as a third row. That third row is
/// not here, and its absence is deliberate: recomputing every stored age in an archive is not a
/// neighbour of asking the server what changed. A divider between two rows says "these belong
/// together"; recompute keeps its own card and its own whitespace on `SettingsScreen`, which is
/// the structural rule that screen was built on. See `docs/settings-v2-inventory.md`, D8.
///
/// What the import *did* change is worth keeping: these two were previously the tail of one long
/// sync card, below the switch, where a reset sat four rows under an unrelated toggle. They read
/// better as a labelled pair.
struct SyncAdvancedSection: View {
    let model: SyncStatusModel

    @State private var confirmingReset = false
    @State private var showingReport = false

    var body: some View {
        VStack(spacing: 0) {
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
                        .foregroundStyle(Color.terracottaDeep)
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
                    .foregroundStyle(Color.terracottaDeep)
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

// MARK: - The secondary screen

/// Where the dry run and the reset live now.
///
/// **Moved rather than deleted, and the copy came with them unchanged.** They were a top-level
/// `Advanced` card on the main Settings screen, which put two diagnostics for a sync-pull engine
/// that still ships behind a flag — and has never met a real archive — at the same level as the
/// archive and the account. That reads as part of ordinary use. One row inside the Syncing card
/// says what they are and gets out of the way.
///
/// The dry run is the thing that gets read before the pull flag is flipped, and that is still
/// ahead. Neither action is going anywhere.
struct SyncDiagnosticsScreen: View {
    let model: SyncStatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("For working out what a pull would do before turning one on. Nothing here changes your archive.")
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                SettingsCard { SyncAdvancedSection(model: model) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.screenMargin)
            .padding(.bottom, 20)
        }
        // Filled explicitly rather than relying on the card inside to stretch the scroll view: a
        // background that sizes to its content leaves the page in the system's own colour down
        // both margins, which on a cream app is a white gutter.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .navigationTitle("Sync diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
