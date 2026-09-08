import SwiftData
import SwiftUI

/// Everything about syncing, one level down from Settings.
///
/// **All of it used to sit on the main Settings scroll, at the same level as the archive and the
/// account.** Two counts that could disagree, a retry that reported that it had done nothing, and a
/// "Sync diagnostics" row that described only the *pull* — so it answered "Nothing to change" while
/// a dozen uploads were stalled, which is true and unreadable next to an upload problem.
///
/// Settings keeps one row with one status sentence. This is where the detail lives.
struct SyncScreen: View {
    let uploads: SyncUploadsModel
    let transcription: TranscriptionQueue?
    let pull: SyncStatusModel?

    @State private var showingDryRun = false
    @State private var showingCaptionProbe = false
    /// The server's word on whether this household may add new media (phase 147). Every row the
    /// retry below can reach is a media upload, so this is the one condition `SyncUploadsModel`
    /// cannot see — it never asks the server anything.
    @Environment(\.mayAddMedia) private var mayAddMedia

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                uploadsGroup
                if let transcription {
                    group("Transcripts") {
                        SettingsCard { TranscriptionBacklogSection(queue: transcription) }
                    }
                }
                if let pull { pullingGroup(pull) }
                group("Photo caption check") {
                    SettingsCard {
                        SettingsRow(label: "Photo caption check") { showingCaptionProbe = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.screenMargin)
            .padding(.bottom, 20)
        }
        // Filled explicitly rather than relying on the cards to stretch the scroll view: a
        // background that sizes to its content leaves white gutters down a cream app.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .navigationTitle("Syncing")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingCaptionProbe) { CaptionProbeScreen() }
        .navigationDestination(isPresented: $showingDryRun) {
            if let pull { SyncDiagnosticsScreen(model: pull) }
        }
        // A background upload can land while this screen is open, and a sweep can finish from
        // elsewhere. Re-read rather than leaving the list stale.
        .onAppear { uploads.refresh() }
    }

    // MARK: Uploads

    @ViewBuilder
    private var uploadsGroup: some View {
        group("Uploads") {
            SettingsCard {
                // **The split phase 20 introduced, kept.** Waiting and stalled are two sentences
                // because one finishes by itself and the other needs a person. What changed is that
                // both now count the same rows, read once, so they can no longer contradict.
                VStack(alignment: .leading, spacing: 6) {
                    if uploads.counts.isClear {
                        Text("Everything's uploaded.").typeRole(.body).foregroundStyle(Color.ink)
                    } else {
                        if let waiting = SyncCounts.waitingLine(uploads.counts) {
                            Text(waiting).typeRole(.body).foregroundStyle(Color.ink)
                        }
                        if let stalled = SyncCounts.stalledLine(uploads.counts) {
                            // `inkMuted`, never red: a file that stopped trying is a fact about a
                            // connection, not an emergency.
                            Text(stalled).typeRole(.metadata).foregroundStyle(Color.inkMuted)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.cardPadding)

                // **`mayAddMedia` as well as the counts, since phase 147.** Every row this retry can
                // reach is a media upload, and a household the server will answer `402
                // subscription_required` to has none it can move: `retry()` resets the ladder, the
                // sweep re-requests, the server refuses, and the rows land back where they were.
                // `SyncUploadsModel.canRetry` states the rule — *"Never show a control that cannot
                // act"* — and this is the one condition it cannot see, because it is the server's
                // and this model never asks the server anything. The counts above stay: they are
                // true, and they are what a parent came to this screen to read.
                if !uploads.counts.isClear, mayAddMedia {
                    SettingsDivider()
                    SettingsActionRow(
                        label: uploads.isRetrying ? "Retrying" : "Retry now",
                        detail: uploads.outcome ?? uploads.retryDisabledReason,
                        isBusy: uploads.isRetrying,
                        isEnabled: uploads.canRetry
                    ) { Task { await uploads.retry() } }
                }

                // **Readouts, not links.** The prompt for this phase asked for each row to tap
                // through to the entry it belongs to, and that is dropped deliberately: reaching
                // `EntryDetailScreen` from Settings means supplying it an `openComposer` and an
                // `onDeleted` that Settings has nowhere to send, so a tappable row here would
                // trade one dead control for two, one screen deeper. The visibility — which files,
                // what state, how big, how many tries — is the part that lets somebody act, and
                // that is all here.
                ForEach(uploads.rows) { row in
                    SettingsDivider()
                    SettingsValueRow(label: kindLabel(row.kind), value: rowValue(row))
                }
            }
        }
    }

    /// Kind, size, state and attempts on one line, because the row's own affordance is the tap
    /// through to the entry it belongs to.
    private func rowValue(_ row: SyncUploadRow) -> String {
        [row.stateLabel, row.sizeLabel, row.attemptsLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "audio": "Voice"
        case "photo": "Photo"
        case "video": "Video"
        default: kind.capitalized
        }
    }

    // MARK: Pulling

    @ViewBuilder
    private func pullingGroup(_ model: SyncStatusModel) -> some View {
        group("Pulling") {
            SettingsCard {
                SyncPullSection(model: model)
                SettingsDivider()
                // **Renamed from "Sync diagnostics".** That name read as a diagnosis of the whole
                // subsystem, which is why "Nothing to change" was confusing beside a dozen stalled
                // uploads — it only ever described what the *pull* would do.
                SettingsRow(label: "Pull dry run") { showingDryRun = true }
                Text("Describes only what the server would send. It changes nothing.")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Layout.cardPadding)
                    .padding(.bottom, Layout.cardPadding)
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader(title)
            content()
        }
    }
}

/// What the pushed row shows when there is no `EntrySync` at all.
///
/// **Said plainly rather than rendered as an empty list**, because an empty list of uploads reads as
/// "nothing to upload" — which is a claim, and not one this screen is in a position to make.
struct SyncUnavailableScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Syncing isn't set up on this device yet.")
                .typeRole(.body)
                .foregroundStyle(Color.ink)
            Text("Nothing has been lost. This fills in once the app has finished starting up.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Layout.screenMargin)
        .background(Color.canvas)
        .navigationTitle("Syncing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
