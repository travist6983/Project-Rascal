import SwiftUI

/// The report behind "Photo caption check".
///
/// **A diagnostic surface, and deliberately a plain one.** It exists to produce one number that
/// decides whether phase 33's device half is worth building at all — see `CaptionProbe`. It is
/// not a feature, it does not persist anything, and if the number comes back near zero this
/// screen is deleted along with the probe.
///
/// It sits behind a row rather than on the Settings page for the same reason the sync diagnostics
/// do: a tool for answering a question about an unshipped feature must not read as part of
/// ordinary use.
struct CaptionProbeScreen: View {
    @State private var state: ProbeState = .idle
    @State private var task: Task<Void, Never>?

    /// Named `ProbeState` rather than `State`: a nested type called `State` shadows SwiftUI's
    /// property wrapper inside this scope, and `@State` then fails to resolve as an attribute.
    private enum ProbeState {
        case idle
        case running
        case done(CaptionProbe.Report)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                explanation
                SettingsCard { control }
                if case .done(let report) = state { results(report) }
                if case .failed(let message) = state { failure(message) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.screenMargin)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .navigationTitle("Photo caption check")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Counts how many photos on this phone already carry a written description in their file.")
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing is uploaded, nothing is saved, and no photo is downloaded from iCloud. It reads a metadata field and counts. Newest \(CaptionProbe.sampleCeiling) photos.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .running:
            SettingsRow(label: "Stop") { task?.cancel() }
        case .idle:
            SettingsRow(label: "Run the check") { start() }
        case .done, .failed:
            SettingsRow(label: "Run it again") { start() }
        }
    }

    /// The numbers, and then the captions themselves.
    ///
    /// **`hitRate` is optional and rendered as such.** Nothing read means the rate is unmeasured,
    /// not zero, and printing "0%" for a scan that could not open a single file would answer this
    /// phase's question wrongly and permanently — the one outcome this screen exists to avoid.
    @ViewBuilder
    private func results(_ report: CaptionProbe.Report) -> some View {
        SettingsCard {
            SettingsValueRow(label: "Photos read", value: "\(report.scanned - report.unreadable)")
            SettingsDivider()
            SettingsValueRow(label: "With a description", value: "\(report.hits)")
            SettingsDivider()
            SettingsValueRow(label: "Share", value: Self.rate(report.hitRate))
            if report.skippedInCloud > 0 {
                SettingsDivider()
                SettingsValueRow(label: "In iCloud, not read", value: "\(report.skippedInCloud)")
            }
            if report.unreadable > 0 {
                SettingsDivider()
                SettingsValueRow(label: "Could not open", value: "\(report.unreadable)")
            }
        }

        if report.samples.isEmpty {
            Text(report.hits == 0
                 ? "No photo on this phone carries one. That is the answer the check is for — write it down."
                 : "Found some, but none could be shown.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("What they say")
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
                ForEach(Array(report.samples.enumerated()), id: \.offset) { _, sample in
                    Text(sample)
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
    }

    private func failure(_ message: String) -> some View {
        Text(message)
            .typeRole(.metadata)
            .foregroundStyle(Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func start() {
        task?.cancel()
        state = .running
        task = Task {
            do {
                let report = try await CaptionProbe.run()
                if Task.isCancelled { return }
                state = .done(report)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed("The check could not finish. \(error.localizedDescription)")
            }
        }
    }

    /// One decimal place, because the interesting distinction is between "none" and "a few in a
    /// hundred" and a rounded integer collapses exactly that.
    static func rate(_ value: Double?) -> String {
        guard let value else { return "not measured" }
        return String(format: "%.1f%%", value * 100)
    }
}
