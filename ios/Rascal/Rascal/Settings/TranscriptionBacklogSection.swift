import SwiftData
import SwiftUI

/// "Transcribe backlog", inside the existing sync-status card.
///
/// **Manual, and it stays manual.** Every voice note recorded before this feature existed is
/// sitting in the archive untranscribed, and there can be hundreds. Chewing through them on first
/// launch would be a surprise battery event on a phone somebody is holding while parenting — so
/// the app knows how many there are, says so once, and does nothing until asked.
///
/// The row disappears entirely when there is nothing to do. A settings row that permanently reads
/// "0 waiting" is furniture, and this screen has none.
struct TranscriptionBacklogSection: View {
    let queue: TranscriptionQueue

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    /// Re-read rather than observed: the count comes from a `FetchDescriptor` over media, and a
    /// `@Query` here would rebuild this row on every unrelated media write in the app.
    @State private var waiting = 0
    @State private var failed = 0

    var body: some View {
        Group {
            if let progress = queue.progress {
                SettingsDivider()
                running(progress)
            } else if let report = queue.lastReport {
                SettingsDivider()
                finished(report)
            } else if waiting > 0 || failed > 0 {
                // `failed` on its own is enough to show the row. Those are words this phone has
                // and the server does not, and nothing retries them without being asked.
                SettingsDivider()
                idle
            }
        }
        .onAppear(perform: recount)
        .onChange(of: queue.progress) { _, _ in recount() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recount() }
        }
    }

    // MARK: States

    private var idle: some View {
        SettingsActionRow(
            label: "Transcribe backlog",
            detail: detail,
            isEnabled: !queue.isRunning
        ) {
            Task { await queue.runBacklog() }
        }
    }

    /// Says how many and what it costs, and nothing about how long it has been left undone.
    private var detail: String {
        var sentence = ""
        if waiting > 0 {
            let noun = waiting == 1 ? "voice note has" : "voice notes have"
            sentence = "\(waiting) \(noun) no transcript yet. Transcribing happens on this phone, "
                + "one at a time, and it warms the battery — so it runs when you ask and not before."
        }
        if failed > 0 {
            let clause = failed == 1 ? "1 didn't finish" : "\(failed) didn't finish"
            sentence += sentence.isEmpty
                ? "\(clause) last time. Trying again is all this does."
                : " \(clause) last time and will be tried again."
        }
        return sentence
    }

    private func running(_ progress: TranscriptionQueue.Progress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Clamped, because the counter is incremented after each row finishes and the view can
            // render in the gap before the run tears its progress down — which showed "4 of 3".
            Text("Transcribing \(min(progress.completed + 1, progress.total)) of \(progress.total)")
                .typeRole(.body)
                .foregroundStyle(Color.ink)
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                .tint(.terracotta)
            Text("You can leave this screen. It keeps going.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop") { queue.cancelBacklog() }
                .typeRole(.body)
                .foregroundStyle(Color.terracotta)
        }
        .padding(Layout.cardPadding)
    }

    /// The counts, plainly. Skipped is named separately from failed because they are different
    /// facts — one is about this phone, the other is about a recording.
    private func finished(_ report: TranscriptionQueue.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.summary(report))
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Done") { queue.clearReport() }
                    .typeRole(.body)
                    .foregroundStyle(Color.terracotta)
                if waiting > 0 {
                    Button("Keep going") { Task { await queue.runBacklog() } }
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                }
            }
        }
        .padding(Layout.cardPadding)
    }

    /// One sentence for what a run did.
    ///
    /// Written out rather than assembled from a table, because "0 transcribed, 0 skipped,
    /// 12 failed" is a report about a program and this is a sentence for a parent.
    static func summary(_ report: TranscriptionQueue.Report) -> String {
        if report.attempted == 0 {
            return report.cancelled
                ? "Stopped before anything was transcribed."
                : "Nothing needed transcribing."
        }
        var parts: [String] = []
        if report.transcribed > 0 {
            parts.append(report.transcribed == 1 ? "1 transcribed" : "\(report.transcribed) transcribed")
        }
        if report.skipped > 0 {
            // Not a failure. This phone could not run the model — for a locale, or for a
            // download that has not finished — and the recordings are exactly as they were.
            parts.append("\(report.skipped) this phone couldn't do")
        }
        if report.failed > 0 {
            parts.append("\(report.failed) didn't finish")
        }
        let sentence = parts.joined(separator: ", ") + "."
        return report.cancelled ? sentence + " Stopped early." : sentence
    }

    private func recount() {
        waiting = TranscriptionQueue.backlogCount(in: context)
        failed = TranscriptionQueue.failedCount(in: context)
    }
}
