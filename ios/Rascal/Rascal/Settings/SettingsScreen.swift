import SwiftData
import SwiftUI

/// Who the archive is for, who is holding it, how to get it out, and whether it has all landed.
///
/// **Settings is not a control panel.** It is the same warm, quiet app one screen deeper, so it
/// uses the app's own shapes rather than the system's grouped list, and it says nothing in red
/// however irreversible a row is. There are no preferences here because none exist — no
/// notification section, no theme. A settings screen full of controls that do nothing is worse
/// than a short one that is true.
///
/// **The screen opens on the child, not on configuration.** That is the design import's argument
/// and this phase adopted it: `ChildHeroCard` takes the place of the old `Name` row, and the
/// small-caps labels beneath it now carry a rule out to the trailing edge so nine stacked blocks
/// read as nine groups rather than one column.
///
/// The one structural rule worth stating out loud: **irreversible actions live in their own card
/// at the bottom, separated by whitespace, never adjacent to an ordinary edit row.** A divider
/// between two rows says "these belong together"; a gap says "these do not". Recomputing every
/// stored age in an archive is not a neighbour of changing a name — which is why the import's
/// `Advanced` group, which lists recompute third under a dry run, was split rather than adopted.
/// See `docs/settings-v2-inventory.md`, D8.
struct SettingsScreen: View {
    let childId: UUID
    let session: AppSession
    /// Signing out belongs to `OnboardingGate`, which owns session state — it has to forget the
    /// Apple subject and any half-finished setup draft, and put the app back on the welcome
    /// screen. Calling `AppSession.signOut()` from here would revoke the token and leave this
    /// screen exactly where it is.
    let onSignOut: () async -> Void
    /// The app's one sync, so the status section reads the same numbers the sweep acts on rather
    /// than inventing a second source of truth for upload state.
    let sync: EntrySync?
    /// The pull half. Optional for the same reason `sync` is: the screen is buildable in a test
    /// without one, and it renders the upload rows and nothing else when it has none.
    var syncEngine: SyncEngine?
    /// The backlog action. Optional too, and its row is absent rather than empty when there is
    /// no queue or nothing waiting.
    var transcription: TranscriptionQueue?
    /// Permission and the daily-note preference. Optional for the same reason `sync` is — this
    /// screen is buildable in a test without one, and it renders every other section unchanged
    /// when it has none.
    var notifications: NotificationPreference?
    /// Reports the child's timezone whenever this screen learns it, because this is the only
    /// screen that can change it.
    ///
    /// The widget snapshot is stamped with the zone its staleness is judged in, and the value
    /// `RootView` was handed came from the gate at launch. Without this, moving the child to
    /// another timezone leaves every snapshot written for the rest of the session stamped with
    /// the old one — and a staleness check run against the wrong zone is exactly how yesterday's
    /// mission ends up on the Home Screen presented as today's.
    var onTimezoneResolved: (String) -> Void = { _ in }

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
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .typeRole(.display)
                    .foregroundStyle(Color.ink)

                ChildHeroCard(child: child) { openChild() }

                archiveSection
                accountSection
                exportSection
                syncSection

                if let notifications {
                    NotificationSettingsSection(
                        preference: notifications,
                        familyTimezone: child?.familyTimezone
                    )
                }

                advancedSection
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

                closingNote
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
            await loadChild()
        }
        // **`sync` arrives late for exactly the same reason `syncEngine` does**, and the counts
        // are worse than the rows when they are wrong: with no `EntrySync` the default
        // `Outstanding` is all zeroes, which `syncSummary` reads as clear — so the card said
        // "Everything's uploaded." on the strength of never having looked. That was survivable
        // when it was a quiet row and is not now that it is the headline of a card.
        //
        // Counted once on appear and again the moment the sweep exists.
        .onChange(of: sync != nil, initial: true) { _, _ in refreshOutstanding() }
        // **Not in `.task`, because `.task` runs once and the engine can arrive after it.**
        //
        // `RootView` builds the `SyncEngine` in its own `.task`, and this screen is handed
        // whatever that property holds at the moment it renders. Landing here first — a launch
        // straight onto this tab — meant `syncEngine` was still nil when `.task` fired, so
        // `syncStatus` was never built and never retried: the pull rows, the dry run and the
        // reset were all silently absent for the life of the session, with nothing on screen
        // saying so. The redesign made that failure louder rather than safer, because `Advanced`
        // is now a whole labelled card that simply is not there.
        //
        // `initial: true` covers the ordinary case where the engine already exists on first
        // render, so this replaces the `.task` line rather than racing it.
        .onChange(of: syncEngine != nil, initial: true) { _, _ in
            if syncStatus == nil, let syncEngine {
                syncStatus = SyncStatusModel(engine: syncEngine)
            }
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
            Button("Sign out", role: .destructive) { Task { await onSignOut() } }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text("The archive stays on the server. Anything still waiting to upload from this phone will finish after you sign back in.")
        }
    }

    // MARK: Archive

    /// **`Name` is not here — `ChildHeroCard` is the name row now.** It opens the same sheet these
    /// two do, so nothing moved further away; one row left the list and the child gained a face.
    private var archiveSection: some View {
        section("The archive") {
            SettingsCard {
                // `openChild()` rather than assigning the route directly: the sheet needs a
                // child to build its model from, and tapping a row while the fetch is still in
                // flight would present an empty sheet you have to dismiss.
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
        section("You") {
            SettingsCard {
                // Three states, not two. "Not set" is a claim about the server, and the app can
                // now make it: the record is stored between launches and re-read from `GET /me`
                // on every launch that has a network. The third state survives anyway — a first
                // launch that has never reached the server has no record to show, and the row
                // shows no value at all rather than asserting something it has not checked.
                SettingsRow(
                    label: "Your name",
                    value: accountNameValue
                ) { route = .editProfile }
                SettingsDivider()
                // Read-only and nil-safe: Apple's relay addresses are unreliable and the column
                // is nullable, so this is words in both states rather than a blank.
                SettingsValueRow(
                    label: "Email",
                    value: session.user?.email ?? AppConfig.devLoginEmail
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

    // MARK: Keep a copy

    private var exportSection: some View {
        section("Keep a copy") {
            SettingsCard { exportRow }
        }
    }

    /// Four states, of which the design import drew one.
    ///
    /// Idle is a card rather than a row now — a terracotta headline over a sentence, which is what
    /// makes the export read as a keepsake instead of a menu item. The import's third line, `Last
    /// export — never`, is not built: nothing records when an export last ran, and inventing a
    /// timestamp is worse than leaving the line out. See `docs/settings-v2-inventory.md`, Q13.
    ///
    /// The other three are unchanged. The import shows no in-flight, ready or failed treatment for
    /// anything on this screen, and a mockup that omits a state is not a mockup that removes one.
    @ViewBuilder
    private var exportRow: some View {
        let state = export?.state ?? .idle
        switch state {
        case .idle:
            Button { export?.start(childId: childId) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Export the archive")
                        .typeRole(.cardTitle)
                        .foregroundStyle(Color.terracotta)
                    Text("Every entry, photo and recording, as a zip you can keep forever.")
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.cardPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Export the archive. Every entry, photo and recording, as a zip you can keep forever.")
            .accessibilityAddTraits(.isButton)

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

    // MARK: Syncing

    private var syncSection: some View {
        section("Syncing") {
            SettingsCard {
                syncHeader
                // Only when there is something to retry. A row that reads "Retry now" beside
                // "Everything's uploaded" is furniture, and this screen has none.
                if !outstanding.isClear {
                    SettingsDivider()
                    SettingsActionRow(
                        label: isRetrying ? "Retrying" : "Retry now",
                        isBusy: isRetrying
                    ) { Task { await retry() } }
                }
                if let transcription { TranscriptionBacklogSection(queue: transcription) }
                if let syncStatus { SyncPullSection(model: syncStatus) }
            }
        }
    }

    private var syncHeader: some View {
        let summary = Self.syncSummary(outstanding)
        return SettingsCardHeader(
            eyebrow: summary.eyebrow,
            counter: summary.counter,
            headline: summary.headline,
            detail: summary.detail,
            isActive: summary.isActive
        )
    }

    /// Everything the sync card's head says, in both of its states.
    ///
    /// A value rather than a view body, for the same reason `TranscriptionBacklogSection.summary`
    /// and `RecomputeAgesModel.summary` are: these are sentences a parent reads at the one moment
    /// they are worried about whether their photos are safe, and a sentence that can only be
    /// checked by looking at a simulator is a sentence nothing checks.
    ///
    /// Never a badge, never red, never a nudge — a photo that has not uploaded yet is a fact about
    /// the network, and the app does not imply otherwise. The wash the design import puts behind
    /// the active state is the same terracotta the app uses for everything else in progress; it
    /// means live, not wrong.
    struct SyncSummary: Equatable {
        let eyebrow: String
        /// Absent when there is nothing to count — never the string "0".
        let counter: String?
        let headline: String
        let detail: String?
        /// Tints the wash and lights the dot.
        let isActive: Bool
    }

    /// "3 entries and 2 files still to upload." — a count, not an accusation.
    static func syncSummary(_ outstanding: EntrySync.Outstanding) -> SyncSummary {
        guard !outstanding.isClear else {
            return SyncSummary(
                eyebrow: "Sync",
                counter: nil,
                headline: "Everything's uploaded.",
                detail: nil,
                isActive: false
            )
        }

        var parts: [String] = []
        let writes = outstanding.entries + outstanding.deletions
        if writes > 0 { parts.append(writes == 1 ? "1 entry" : "\(writes) entries") }
        if outstanding.media > 0 {
            parts.append(outstanding.media == 1 ? "1 file" : "\(outstanding.media) files")
        }
        let subject = parts.joined(separator: " and ")

        return SyncSummary(
            eyebrow: "Uploading",
            counter: "\(outstanding.total) left",
            headline: "\(subject) still to upload.",
            detail: "They'll finish on their own when you're back on a good connection.",
            isActive: true
        )
    }

    // MARK: Advanced

    /// The dry run and the reset, in the import's own grouping — minus the third row it puts
    /// beside them. See `dangerSection`.
    ///
    /// Absent entirely when there is no `SyncEngine`, rather than shown as an empty labelled
    /// shell: the screen is buildable in a test without one, and a card with nothing in it under
    /// a rule that says "Advanced" is exactly the furniture this screen refuses everywhere else.
    @ViewBuilder
    private var advancedSection: some View {
        if let syncStatus {
            section("Advanced") {
                SettingsCard { SyncAdvancedSection(model: syncStatus) }
            }
        }
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
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader("Corrections")
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
        VStack(alignment: .leading, spacing: 9) {
            SettingsSectionHeader(title)
            content()
        }
    }

    /// The line the import closes the screen on.
    ///
    /// Adopted because it is true and because it is the one sentence on this screen that explains
    /// why none of the rest of it is alarming. Set `inkMuted`, not the import's `inkFaint`: that
    /// measures 2.13:1 on the canvas, and this is a sentence meant to be read.
    private var closingNote: some View {
        Text("Rascal writes to this phone first. Everything you see here exists whether or not the network does.")
            .typeRole(.metadata)
            .foregroundStyle(Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 4)
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
            // Also covers a change made on another device: this is the freshest the client ever
            // sees the zone, whether or not it was edited here.
            if let zone = child?.familyTimezone { onTimezoneResolved(zone) }
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
        onTimezoneResolved(updated.familyTimezone)
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
