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
        /// The library is closed to the app. **A state of its own, not a `failed` string** — the
        /// check did not break, there is simply nothing to look at.
        ///
        /// It carries the grant because *"never asked"* and *"said no"* need different sentences,
        /// which is a distinction the rest of the app already treats as load-bearing: see
        /// `AddToArchiveModel.cameraRollSubtitle`, where `.notDetermined` is an invitation and
        /// `.denied` is one honest line with no funnel behind it.
        case unauthorized(BackfillAuthorization)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                explanation
                SettingsCard { control }
                if case .done(let report) = state { results(report) }
                if case .unauthorized(let grant) = state { unauthorized(grant) }
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
        case .done, .failed, .unauthorized:
            SettingsRow(label: "Run it again") { start() }
        }
    }

    /// **No prompt from here, and no retry funnel.** The probe reads the authorization status and
    /// never requests it — `CaptionProbe.currentAuthorization` says why — so the only honest thing
    /// this screen can offer is the place the answer actually lives.
    private func unauthorized(_ grant: BackfillAuthorization) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The check needs access to your photos")
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.unauthorizedExplanation(for: grant))
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            // **Only where Settings can actually change the answer.** The sentence above
            // deliberately makes no Settings promise to a parent who has never been asked, because
            // iOS creates no photo row for an app until it has requested authorization — and a
            // button doing what the copy just declined to do is the louder of the two.
            if grant == .denied {
                SettingsLinkText()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// **Two sentences, because the two states have different true answers.**
    ///
    /// Pointing a parent who has already refused back at the camera roll browser would be sending
    /// them to a screen that cannot ask again — iOS shows its prompt once — and reads as a retry
    /// funnel, which `docs/decisions.md` settles this app does not build. Settings is the only
    /// place that answer can change, so after a refusal Settings is the only thing named.
    static func unauthorizedExplanation(for grant: BackfillAuthorization) -> String {
        switch grant {
        case .denied:
            return "Photo access is off, so there's nothing to count. It can be turned back on in Settings."
        default:
            // **No Settings promise here.** iOS creates no photo row on an app's Settings page
            // until the app has actually asked, so telling a parent who has never been asked to
            // go and change it there sends them to look for something that is not on the screen.
            return "There's nothing to count until the app has some. Photo access is asked for the first time you browse your camera roll."
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

        // **The rate this screen exists to produce is a rate over a real camera roll.** Measured
        // over a shared selection it is a different question, and a percentage that does not say
        // which one it answered is exactly the kind of number that gets written down as fact.
        if report.limitedLibrary {
            Text("Measured over the photos shared with Pocket Chronicle, not the whole library — so this share answers a smaller question than the one the check is for.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }

        if report.samples.isEmpty {
            // **The zero verdict is a claim about the phone, so it may only be made about the
            // phone.** Under a shared selection the honest version says what was actually looked
            // at — printing "no photo on this phone carries one" over a handful of shared pictures
            // would answer this screen's whole question wrongly, and it is the kind of sentence
            // that gets written down as a fact.
            Text(Self.emptyVerdict(hits: report.hits, limited: report.limitedLibrary))
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

    /// What to say when no caption could be shown.
    static func emptyVerdict(hits: Int, limited: Bool) -> String {
        guard hits == 0 else { return "Found some, but none could be shown." }
        return limited
            ? "None of the photos shared with Pocket Chronicle carries one. Share the whole library to answer this properly."
            : "No photo on this phone carries one. That is the answer the check is for — write it down."
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
            } catch CaptionProbe.ProbeError.notAuthorized(let grant) {
                state = .unauthorized(grant)
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
