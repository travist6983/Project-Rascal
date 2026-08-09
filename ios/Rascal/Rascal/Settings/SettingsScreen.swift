import SwiftData
import SwiftUI

/// Who the archive is for, who is holding it, how to get it out, and whether it has all landed.
///
/// **Settings is not a control panel.** It is the same warm, quiet app one screen deeper, so it
/// uses the app's own shapes rather than the system's grouped list, and it says nothing in red
/// however irreversible a row is. There are no preferences here because none exist — no toggles,
/// no notification section, no theme. A settings screen full of controls that do nothing is
/// worse than a short one that is true.
///
/// The one structural rule worth stating out loud: **irreversible actions live in their own card
/// at the bottom, separated by whitespace, never adjacent to an ordinary edit row.** A divider
/// between two rows says "these belong together"; a gap says "these do not". Recomputing every
/// stored age in an archive is not a neighbour of changing a name.
struct SettingsScreen: View {
    let childId: UUID
    let session: AppSession
    /// The app's one sync, so the status section reads the same numbers the sweep acts on rather
    /// than inventing a second source of truth for upload state.
    let sync: EntrySync?
    /// The pull half. Optional for the same reason `sync` is: the screen is buildable in a test
    /// without one, and it renders the upload rows and nothing else when it has none.
    var syncEngine: SyncEngine?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var child: ChildResponse?
    @State private var notice: String?
    @State private var route: Route?
    @State private var confirmingSignOut = false
    @State private var confirmingRecompute = false
    @State private var outstanding = EntrySync.Outstanding()
    @State private var isRetrying = false
    @State private var export: ArchiveExport?
    @State private var recompute: RecomputeAgesModel?
    @State private var syncStatus: SyncStatusModel?

    /// Which sheet is up. One piece of state rather than a boolean per sheet, so two cannot be
    /// true at once.
    private enum Route: Identifiable {
        case editChild, editProfile
        var id: Int { self == .editChild ? 0 : 1 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .typeRole(.display)
                    .foregroundStyle(Color.ink)

                archiveSection
                accountSection
                yourDataSection
                appSection

                if let notice {
                    Text(notice)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 2)
                }

                // Irreversible, and set apart. The whitespace is the point.
                dangerSection

                signOutButton
            }
            .padding(Layout.screenMargin)
            .padding(.bottom, 20)
        }
        .background(Color.canvas)
        .task {
            // The only moment nothing can be referencing a staged zip. See `purgeStale`.
            ArchiveExport.purgeStale()
            if export == nil { export = ArchiveExport(api: session.api) }
            if recompute == nil { recompute = RecomputeAgesModel(childId: childId, api: session.api) }
            if syncStatus == nil, let syncEngine { syncStatus = SyncStatusModel(engine: syncEngine) }
            refreshOutstanding()
            await loadChild()
        }
        // Leaving the tab tears this view down while the download would carry on writing to a
        // file nobody is going to open. Cancelled rather than orphaned.
        .onDisappear { export?.cancel() }
        // A sweep can finish while this screen is open — from a foreground elsewhere, or from a
        // background upload landing — so the counts are re-read rather than left stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshOutstanding() }
        }
        .sheet(item: $route) { route in
            switch route {
            case .editChild:
                if let child {
                    EditChildSheet(model: EditChildModel(child: child, api: session.api)) { updated in
                        apply(updated)
                    }
                }
            case .editProfile:
                EditProfileSheet(
                    model: EditProfileModel(
                        user: session.user,
                        fallbackEmail: AppConfig.devLoginEmail,
                        api: session.api
                    )
                ) { updated in
                    session.apply(user: updated)
                }
            }
        }
        .confirmationDialog(
            "Recompute every stored age?",
            isPresented: $confirmingRecompute,
            titleVisibility: .visible
        ) {
            Button("Recompute") { Task { await runRecompute() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every entry's age is worked out again from \(child?.name ?? "your child")'s birthday. Nothing else about your entries changes.")
        }
        .confirmationDialog(
            "Sign out?",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text("The archive stays on the server. Anything still waiting to upload from this phone will finish after you sign back in.")
        }
    }

    // MARK: Archive

    private var archiveSection: some View {
        section("Archive") {
            SettingsCard {
                // `openChild()` rather than assigning the route directly: the sheet needs a
                // child to build its model from, and tapping a row while the fetch is still in
                // flight would present an empty sheet you have to dismiss.
                SettingsRow(
                    label: "Name",
                    value: child?.name
                ) { openChild() }
                SettingsDivider()
                SettingsRow(
                    label: "Birthday",
                    value: child.map { formattedBirthdate($0.birthdate) }
                ) { openChild() }
                SettingsDivider()
                SettingsRow(
                    label: "Timezone",
                    value: child.map { TimeZoneCatalog.city($0.familyTimezone) }
                ) { openChild() }
            }
        }
    }

    // MARK: Account

    private var accountSection: some View {
        section("Account") {
            SettingsCard {
                // Three states, not two. "Not set" is a claim about the server, and this app
                // cannot make it after a warm start: the token is in the keychain, the user
                // record came back with the sign-in response, and there is no `GET /me` to ask
                // again. When the record is absent the row shows no value at all rather than
                // asserting something it has not checked.
                SettingsRow(
                    label: "Your name",
                    value: accountNameValue,
                    valueIsMuted: session.user?.displayName == nil
                ) { route = .editProfile }
                SettingsDivider()
                // Read-only and nil-safe: Apple's relay addresses are unreliable and the column
                // is nullable, so this is words in both states rather than a blank.
                SettingsValueRow(
                    label: "Email",
                    value: session.user?.email ?? AppConfig.devLoginEmail,
                    valueIsMuted: session.user?.email == nil
                )
            }
        }
    }

    /// Ignored until the child has loaded. Nothing to say about it, so nothing is presented.
    private func openChild() {
        guard child != nil else { return }
        route = .editChild
    }

    /// The name, "Not set" when the server says there is none, and nothing when this launch
    /// never learned the user record.
    private var accountNameValue: String? {
        guard let user = session.user else { return nil }
        return user.displayName ?? "Not set"
    }

    // MARK: Your data

    private var yourDataSection: some View {
        section("Your data") {
            VStack(spacing: Layout.cardSpacing) {
                SettingsCard { exportRow }
                SettingsCard {
                    syncRows
                    if let syncStatus { SyncPullSection(model: syncStatus) }
                }
            }
        }
    }

    @ViewBuilder
    private var exportRow: some View {
        let state = export?.state ?? .idle
        switch state {
        case .idle:
            SettingsActionRow(
                label: "Export archive",
                detail: "Every entry and every photo, as a zip you can keep."
            ) { export?.start(childId: childId) }

        case .running(let fraction):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Preparing your archive")
                        .typeRole(.body)
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    Button("Cancel") { export?.cancel() }
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                }
                // A real measurement: the server sends content-length because it assembles the
                // zip before streaming it.
                ProgressView(value: fraction ?? 0, total: 1)
                    .progressViewStyle(.linear)
                    .tint(.terracotta)
                    .opacity(fraction == nil ? 0.5 : 1)
                Text(fraction.map { "\(Int($0 * 100))%" } ?? "This can take a minute on cellular.")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
            }
            .padding(Layout.cardPadding)

        case .ready(let url, let bytes):
            VStack(alignment: .leading, spacing: 10) {
                Text("Your archive is ready")
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                HStack(spacing: 16) {
                    ShareLink(item: url) {
                        Text("Save or share")
                            .typeRole(.body)
                            .foregroundStyle(Color.terracotta)
                    }
                    Button("Done") { export?.clear() }
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            .padding(Layout.cardPadding)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("Export didn't finish")
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                Text(message)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { export?.start(childId: childId) }
                    .typeRole(.body)
                    .foregroundStyle(Color.terracotta)
            }
            .padding(Layout.cardPadding)
        }
    }

    /// Counts, and one action. Never a badge, never red, never a nudge — a photo that has not
    /// uploaded yet is a fact about the network, and the app does not imply otherwise.
    @ViewBuilder
    private var syncRows: some View {
        if outstanding.isClear {
            SettingsValueRow(label: "Sync", value: "Everything's uploaded")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(waitingSummary)
                    .typeRole(.body)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("They'll finish on their own when you're back on a good connection.")
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(isRetrying ? "Retrying" : "Retry now") { Task { await retry() } }
                        .typeRole(.body)
                        .foregroundStyle(isRetrying ? Color.inkMuted : Color.terracotta)
                        .disabled(isRetrying)
                    if isRetrying { ProgressView().tint(.terracotta) }
                }
            }
            .padding(Layout.cardPadding)
        }
    }

    /// "3 items waiting to upload" — a count, not an accusation.
    private var waitingSummary: String {
        var parts: [String] = []
        let writes = outstanding.entries + outstanding.deletions
        if writes > 0 { parts.append(writes == 1 ? "1 entry" : "\(writes) entries") }
        if outstanding.media > 0 {
            parts.append(outstanding.media == 1 ? "1 file" : "\(outstanding.media) files")
        }
        let subject = parts.joined(separator: " and ")
        return "\(subject) still to upload."
    }

    // MARK: App

    private var appSection: some View {
        section("App") {
            SettingsCard {
                SettingsValueRow(label: "Version", value: Self.version)
            }
        }
    }

    // MARK: Irreversible

    /// Its own card, and its own space above it. Nothing in this section is adjacent to a row
    /// that merely edits a value.
    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Corrections")
                .padding(.horizontal, 2)
            SettingsCard {
                switch recompute?.state ?? .idle {
                case .idle, .running:
                    SettingsActionRow(
                        label: "Recompute ages from birthday",
                        detail: "Ages are saved with each entry as you write it, so fixing a birthday doesn't change them. This works them all out again.",
                        isBusy: recompute?.isRunning ?? false
                    ) { confirmingRecompute = true }

                case .done(let updated, let birthdate):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(RecomputeAgesModel.summary(updated: updated, birthdate: birthdate))
                            .typeRole(.body)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Done") { recompute?.dismiss() }
                            .typeRole(.body)
                            .foregroundStyle(Color.terracotta)
                    }
                    .padding(Layout.cardPadding)

                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("That didn't finish")
                            .typeRole(.body)
                            .foregroundStyle(Color.ink)
                        Text(message)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { confirmingRecompute = true }
                            .typeRole(.body)
                            .foregroundStyle(Color.terracotta)
                    }
                    .padding(Layout.cardPadding)
                }
            }
        }
        .padding(.top, 8)
    }

    /// Below everything, where it was. Terracotta is the primary action colour and signing out
    /// is not one; nothing here is red, because red is an urgency state and this is a choice.
    private var signOutButton: some View {
        Button { confirmingSignOut = true } label: {
            Text("Sign out")
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
        }
        .buttonStyle(TapScaleButtonStyle())
        .padding(.top, 8)
    }

    // MARK: Scaffolding

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title).padding(.horizontal, 2)
            content()
        }
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "—"
        }
    }

    /// `yyyy-MM-dd` from the server is a calendar day. Read and shown in the same calendar
    /// `EditChildModel.dayFormatter` uses — mixing zones between the row and the picker is what
    /// made a June birthday render as May.
    private func formattedBirthdate(_ raw: String) -> String {
        guard let date = EditChildModel.dayFormatter.date(from: raw) else { return raw }
        let display = DateFormatter()
        display.locale = .autoupdatingCurrent
        display.timeZone = .current
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    // MARK: Actions

    private func loadChild() async {
        do {
            let children = try await session.api.children()
            child = children.first { $0.id == childId } ?? children.first
            notice = nil
        } catch let error as APIError {
            // The screen still shows the account, the version, and the sync state. Offline is
            // not a failure worth an empty page.
            notice = child == nil ? error.userMessage : nil
        } catch {
            notice = child == nil ? error.localizedDescription : nil
        }
    }

    /// Fold the saved child back into the row values without a refetch.
    private func apply(_ updated: ChildUpdateResponse) {
        guard let existing = child else { return }
        child = ChildResponse(
            id: existing.id,
            name: updated.name,
            birthdate: updated.birthdate,
            familyTimezone: updated.familyTimezone,
            // Unchanged on purpose. `age_months` is the server's, `PATCH` does not return it,
            // and inventing one here would be the client deciding something it does not own.
            ageMonths: existing.ageMonths,
            role: existing.role
        )
    }

    private func runRecompute() async {
        await recompute?.run(context: context)
        refreshOutstanding()
        // The corrected ages are in the archive now; reload the child so the birthday row and
        // the greeting agree with what was just computed against.
        await loadChild()
    }

    /// The existing sweep, not a media-only path. **Entries drain before media** — a media
    /// upload against an entry the server has never seen spends an attempt on a guaranteed 404
    /// and pushes that file's backoff out for nothing.
    private func retry() async {
        guard let sync, !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        await sync.sweep()
        refreshOutstanding()
    }

    private func refreshOutstanding() {
        outstanding = sync?.outstanding() ?? EntrySync.Outstanding()
    }
}
