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

    /// Ask for the add-a-child sheet. **Presented by the gate, not from here**, for the same
    /// reason the switcher is: creating a child ends in a switch, and a switch replaces the whole
    /// view tree this screen is inside — a sheet owned down here would be destroying its own
    /// presenter as it succeeded.
    var onAddChild: () -> Void = {}
    /// The app's one sync, so the status section reads the same numbers the sweep acts on rather
    /// than inventing a second source of truth for upload state.
    let sync: EntrySync?
    /// Reads the child's avatar back — local file first, a presigned GET only if there is none.
    /// Optional for the same reason `sync` is: without one the hero renders its initials disc,
    /// which is also what it renders for a child who has no avatar.
    var avatarSync: AvatarSync?
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
    /// The child's name and pronouns, whenever this screen learns a fresher pair — from the
    /// fetch, and from a save. Pushed up so every already-rendered prompt re-renders without a
    /// relaunch; see `RootView.resolvedPromptSubject`.
    var onPromptSubjectChanged: (PromptSubject) -> Void = { _ in }

    /// **Handed down rather than built here, as of phase 108.**
    ///
    /// This screen used to own it, which was right while Settings was the only door to the
    /// membership sheet. Today now has one too — a locked card — and two `SubscriptionModel`s would
    /// be two `GET /v1/families/me` readers and two opinions about the selected plan. `RootView`
    /// owns the one instance and both tabs read it.
    ///
    /// Optional because it is built in `RootView`'s `.task`, so it is nil for the first frame — the
    /// same shape `sync` and `syncEngine` already have here, and the Membership card renders absent
    /// rather than wrong until it arrives.
    var subscription: SubscriptionModel?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var child: ChildResponse?
    /// Archive-wide counts. Nil until the server answers; the hero renders without the strip
    /// until then, and keeps rendering without it if the call never lands.
    @State private var stats: ChildStatsResponse?
    /// The avatar's bytes once something has them. Nil covers every no-picture case — no avatar,
    /// no connection on a fresh install, a key that 404s — and all of them render the same disc.
    @State private var avatar: Data?
    @State private var notice: String?
    @State private var route: Route?
    @State private var confirmingSignOut = false
    /// Built on first appearance, like `export`: the screen's memberwise init is what
    /// `RootView` calls, and a `@State` with no default would take it away.
    @State private var guardians: GuardiansModel?
    @State private var deletion: AccountDeletionModel?
    @State private var showingDelete = false
    @State private var export: ArchiveExport?
    @State private var syncStatus: SyncStatusModel?
    /// The uploads half, and the only place any upload number on this screen comes from.
    @State private var uploads: SyncUploadsModel?
    /// Whether there is a network path at all. Owned here rather than inside the uploads model so
    /// the Settings row can say "Offline" before that model exists.
    @State private var reachability = NetworkReachability()
    /// Pushes `SyncScreen`. Everything the sync card used to hold lives there now.
    @State private var showingSync = false

    /// Which sheet is up. One piece of state rather than a boolean per sheet, so two cannot be
    /// true at once.
    private enum Route: Identifiable, Hashable {
        case editChild, editProfile, credentials
        /// A legal page, carried as a resolved `URL` rather than as a key.
        ///
        /// **The URL is resolved at the row, not here**, which is what makes an unconfigured build
        /// render the row as *absent* rather than as a control that opens nothing: `LegalLinks`
        /// hands back `URL?`, and a nil never becomes a `Route` at all.
        case legal(URL)
        var id: Int { hashValue }
    }

    var body: some View {
        // **A stack, so `Sync diagnostics` can push rather than present.** The root's own big
        // "Settings" title stays and the navigation bar is hidden under it; the pushed screen
        // turns its own bar back on. Nothing else on this screen gains a chrome it did not have.
        NavigationStack {
            content
                .navigationDestination(isPresented: $showingSync) { syncScreen }
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .typeRole(.display)
                    .foregroundStyle(Color.ink)

                ChildHeroCard(child: child, avatar: avatar, stats: stats) { openChild() }

                archiveSection
                childrenSection
                accountSection
                // Who shares this archive. In "You"'s neighbourhood rather than under
                // `Advanced`: a second parent is the household, not a setting.
                if let guardians, let subscription {
                    GuardiansSection(model: guardians, subscription: subscription)
                }
                // Membership sits under the household it covers, per D4: the subscription is a
                // property of the household, not of the person reading this screen.
                if let subscription { SubscriptionSection(model: subscription) }
                exportSection
                syncSection

                if let notifications {
                    NotificationSettingsSection(
                        preference: notifications,
                        familyTimezone: child?.familyTimezone
                    )
                }

                appSection
                // Beside the version, which is the other thing on this screen that is about the
                // app rather than about the archive. Above the irreversible card, which keeps its
                // whitespace and its isolation.
                aboutSection
                deleteAccountRow

                if let notice {
                    Text(notice)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 2)
                }

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
            if guardians == nil { guardians = GuardiansModel(api: session.api) }
            if deletion == nil { deletion = AccountDeletionModel(api: session.api) }
            await loadChild()
            await loadStats()
        }
        // **`sync` arrives late for exactly the same reason `syncEngine` does.** With no
        // `EntrySync` there is nothing to count, and the old card read that absence as "clear" and
        // said "Everything's uploaded." on the strength of never having looked. The row now shows
        // an em dash until the model exists, because not knowing is a different answer from zero.
        //
        // `initial: true` and keyed on the arrival, so a Settings-first launch is not stranded —
        // the same shape as `syncEngine` below, for the same reason.
        .onChange(of: sync != nil, initial: true) { _, _ in
            if uploads == nil, let sync {
                uploads = SyncUploadsModel(
                    // The app's one sweep, so this screen acts on the same queue the uploader
                    // does rather than starting a second one.
                    sweep: { await sync.sweep() },
                    context: context,
                    reachability: reachability
                )
            }
        }
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
        // **Keyed on all three inputs rather than fired once**, which is the same trap `syncEngine`
        // fell into directly above: `avatarSync` is built in `RootView`'s `.task` and can arrive
        // after this screen first renders, and `child` arrives later still from `loadChild`. A
        // plain `.task` would run while both were nil and never look again, so a parent landing
        // straight on this tab would see initials for the life of the session.
        .task(id: avatarLoadKey) { await loadAvatar() }
        // Leaving the tab tears this view down while the download would carry on writing to a
        // file nobody is going to open. Cancelled rather than orphaned.
        .onDisappear { export?.cancel() }
        // A sweep can finish while this screen is open — from a foreground elsewhere, or from a
        // background upload landing — so the count is re-read rather than left stale.
        //
        // **This is not sufficient on its own and is not claimed to be.** `scenePhase` does not
        // fire while the app stays in the foreground, so a background upload landing while this
        // screen is open does not move the row until something else re-reads. `SyncScreen` refreshes
        // on appear, which is the surface where a stale number would actually mislead.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { uploads?.refresh() }
        }
        .sheet(item: $route) { route in
            switch route {
            case .editChild:
                if let child {
                    EditChildSheet(
                        model: EditChildModel(child: child, api: session.api),
                        // **Nil when there is no `AvatarSync` yet**, which is a state this screen
                        // genuinely renders: it is built in `RootView`'s `.task` and can arrive
                        // after a launch that lands straight on this tab. The sheet drops the photo
                        // field and opens with its other four; the alternative — refusing to open
                        // the sheet at all — would take name, birthday, pronouns and timezone away
                        // over a picture.
                        photo: avatarSync.map { sync in
                            ChildPhotoActions(
                                childName: child.name,
                                avatar: avatar,
                                onChoose: { jpeg in choosePhoto(jpeg, child: child, sync: sync) },
                                onRemove: { removePhoto(child: child, sync: sync) }
                            )
                        }
                    ) { updated in
                        apply(updated)
                    }
                }
            case .credentials:
                CredentialsSheet(model: CredentialsModel(api: session.api))
            // **In the app, not in Safari.** A `Link` or an `openURL` here would send a reviewer —
            // and a parent — out to another app to read our terms and leave them there.
            // `SafariView` is the same wrapper the paywall's two links present.
            case .legal(let url):
                SafariView(url: url).ignoresSafeArea()
            case .editProfile:
                EditProfileSheet(
                    model: EditProfileModel(
                        user: session.user,
                        api: session.api
                    )
                ) { updated in
                    session.apply(user: updated)
                }
            }
        }
        .sheet(isPresented: $showingDelete) {
            if let deletion {
                DeleteAccountSheet(
                    model: deletion,
                    // Changes what the sheet truthfully says: with a second parent in the
                    // household the children stay with them, and telling somebody their
                    // child's archive is about to be deleted when it is not would be a
                    // frightening lie.
                    hasOtherGuardian: (guardians?.family?.guardians.count ?? 1) > 1,
                    onDeleted: {
                        showingDelete = false
                        // The session is already dead server-side — requesting revokes every
                        // refresh token — so this reflects a state rather than causing one.
                        Task { await onSignOut() }
                    },
                    onDismiss: { showingDelete = false }
                )
            }
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
                // **No `Photo` row, and it is not an omission either.** Phase 115 put one here,
                // opening a sheet of its own; phase 117 moved the photo into `EditChildSheet` with
                // the other four fields, so this card is back to the rows that open that sheet.
                // `openChild()` rather than assigning the route directly: the sheet needs a
                // child to build its model from, and tapping a row while the fetch is still in
                // flight would present an empty sheet you have to dismiss.
                SettingsRow(
                    label: "Birthday",
                    value: child.map { formattedBirthdate($0.birthdate) }
                ) { openChild() }
                SettingsDivider()
                // **A null pronoun shows no value, not "Not set".** The same call the `Your name`
                // row makes above, and for the same reason: rendering "Not set" is a claim, and
                // the correct display for an unanswered optional is an empty trailing value.
                //
                // `child?.pronounSet?.label` collapses two nils that mean different things —
                // "not fetched" and "not answered" — and that is deliberate here: both render as
                // nothing, and the row is not the place to distinguish them.
                SettingsRow(
                    label: "Pronouns",
                    value: child?.pronounSet?.label
                ) { openChild() }
                SettingsDivider()
                SettingsRow(
                    label: "Timezone",
                    value: child.map { TimeZoneCatalog.city($0.familyTimezone) }
                ) { openChild() }
            }
        }
    }

    // MARK: Children

    /// **The only way to add a second child, and it has to be here rather than in the switcher.**
    /// The switcher's chevron does not exist until there are two children — which is precisely the
    /// account that needs to add one — so an entry point that lived only there would be sealed
    /// behind its own door, the same shape of bug `AddToArchiveModel` records about the camera
    /// roll row.
    ///
    /// One row, and no list of the children themselves: the switcher already lists them, and a
    /// second list here would be a second place to keep correct for no new capability.
    private var childrenSection: some View {
        section("Children") {
            SettingsCard {
                SettingsRow(label: "Add a child") { onAddChild() }
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
                // is nullable, so this is words in both states rather than a blank — and the
                // words are `EditProfileModel`'s, because the sheet this row opens says the same
                // thing about the same absent value.
                //
                // **Never `AppConfig.devLoginEmail`.** That is a build-configuration constant
                // defaulting to `dev@rascal.local`; rendering it here told a parent whose relay
                // address came back null that a developer's address was their account.
                SettingsValueRow(
                    label: "Email",
                    value: session.user?.email ?? EditProfileModel.absentEmail
                )
                SettingsDivider()
                // The ways into this archive. Deliberately in "You" rather than under
                // `Advanced`: adding a second sign-in method is the difference between an
                // archive one lost Apple ID ends and one that survives it, which is not an
                // advanced concern.
                SettingsRow(label: "Signing in") { route = .credentials }
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
                            .foregroundStyle(Color.terracottaDeep)
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
                    .foregroundStyle(Color.terracottaDeep)
            }
            .padding(Layout.cardPadding)
        }
    }

    // MARK: Syncing

    /// **Exactly one row.** Everything that used to be on this card — two counts that could
    /// disagree, a retry that reported it had done nothing, a "Sync diagnostics" row that described
    /// only the pull — is now one level down, in `SyncScreen`. What stays here is a single status
    /// sentence and a chevron.
    ///
    /// `Export the archive` is deliberately not moved. It is not a sync control.
    private var syncSection: some View {
        section("Syncing") {
            SettingsCard {
                SettingsRow(label: "Syncing", value: syncRowValue) { showingSync = true }
            }
        }
    }

    /// The one true status, from the one model. Before that model exists there is still an honest
    /// answer to give — whether there is a network path — so the row is never blank and never lies
    /// by omission.
    private var syncRowValue: String {
        guard let uploads else {
            return reachability.isOnline ? "—" : SyncCounts.rowValue(.offline)
        }
        return SyncCounts.rowValue(uploads.status)
    }

    // MARK: Syncing, one level down

    /// Built here rather than inside `SyncScreen` so the models outlive a push and a pop: the
    /// uploads model holds the retry's in-flight state, and rebuilding it on every appearance
    /// would drop a "Retrying" mid-flight.
    @ViewBuilder
    private var syncScreen: some View {
        if let uploads {
            SyncScreen(
                uploads: uploads,
                transcription: transcription,
                pull: syncStatus
            )
        } else {
            // No `EntrySync` at all. Said plainly rather than shown as an empty list, which would
            // read as "nothing to upload".
            SyncUnavailableScreen()
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

    // MARK: About

    /// Terms and Privacy, reachable without opening the paywall.
    ///
    /// Guideline 3.1.2 requires both **on the paywall**, and `PaywallSheet.legalRow` carries them
    /// there. This is the second place a reviewer looks, and the only place a parent who never
    /// opened the sheet will find them.
    ///
    /// **There is no Restore row here, and that is deliberate rather than an omission.**
    /// `SubscriptionSection` already offers one under *Membership* — the same scroll, a few
    /// sections up — beside the household it acts on and beside *Manage subscription*. Two
    /// controls calling the identical `model.restore()` on one screen is a defect, not twice the
    /// compliance, and `AppReviewRequirementsTests.theRestoreControlIsInSettings` pins the shipped
    /// one where it is. The phase 126 brief asked for a third row against a stale picture of the
    /// tree; `SubmissionComplianceTests.thereIsOneRestoreControlInSettings` pins that there is exactly one.
    ///
    /// **A row whose URL is unset is absent, never dead** — `LegalLinks`' own contract, and the
    /// reason it guards on `url.host()`. A fresh clone has no `Config.xcconfig`, both keys resolve
    /// to nil, and this whole section disappears rather than drawing a card around nothing. That
    /// state is a release blocker recorded in `blocked.md` §19, not something this view can paper
    /// over by inventing a URL.
    @ViewBuilder
    private var aboutSection: some View {
        let terms = LegalLinks.terms
        let privacy = LegalLinks.privacy

        if terms != nil || privacy != nil {
            section("About") {
                SettingsCard {
                    if let terms {
                        SettingsRow(label: "Terms of Use") { route = .legal(terms) }
                    }
                    if terms != nil, privacy != nil {
                        SettingsDivider()
                    }
                    if let privacy {
                        SettingsRow(label: "Privacy Policy") { route = .legal(privacy) }
                    }
                }
            }
        }
    }

    /// **Its own card, at the bottom, with whitespace above it.** `docs/design-system.md` is
    /// explicit that there is no destructive colour in this product and that an irreversible
    /// action gets its weight from placement instead — so this is terracotta like any other
    /// action, set apart by where it sits rather than by being painted red.
    private var deleteAccountRow: some View {
        SettingsCard {
            SettingsActionRow(
                label: "Delete your account",
                detail: "Nothing happens for seven days, and signing back in undoes it."
            ) {
                showingDelete = true
            }
        }
        .padding(.top, 28)
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
        Text("Pocket Chronicle writes to this phone first. Everything you see here exists whether or not the network does.")
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

    /// **Best effort, and never blocks the screen.** Settings renders the account, the version and
    /// the sync state without it; a failed count is a strip that does not appear, which is the
    /// honest outcome and the same one a cold offline launch gets. No notice is set — there is
    /// nothing for a parent to do about it, and a line of apology under the hero would be noise
    /// about a decoration.
    private func loadStats() async {
        guard let fetched = try? await session.api.childStats(childId: childId) else { return }
        stats = fetched
    }

    private func loadChild() async {
        do {
            let children = try await session.api.children()
            // **No `?? children.first`.** With one child that fallback was unreachable; with two
            // it renders a different child's name, birthdate, avatar and timezone over the
            // `childId` that every write on this screen still uses — `export?.start(childId:)`
            // among them — and then pushes that child's zone and pronouns up through
            // `onTimezoneResolved` and `onPromptSubjectChanged`, which sit above every tab and
            // re-render every prompt in the app. A selection that is not in the response is
            // nothing to show, not somebody else; `ChildHeroCard` already draws that honestly.
            child = children.first { $0.id == childId }
            // Also covers a change made on another device: this is the freshest the client ever
            // sees the zone, whether or not it was edited here.
            if let zone = child?.familyTimezone { onTimezoneResolved(zone) }
            // Also covers a pronoun changed on another device, for the same reason the zone does:
            // this fetch is the freshest the client ever sees either value.
            if let child { onPromptSubjectChanged(child.promptSubject) }
            notice = nil
        } catch let error as APIError {
            // The screen still shows the account, the version, and the sync state. Offline is
            // not a failure worth an empty page.
            notice = child == nil ? error.userMessage : nil
        } catch {
            notice = child == nil ? error.localizedDescription : nil
        }
    }

    /// Everything the avatar read depends on, in one value `.task(id:)` can compare.
    ///
    /// The `avatarSync != nil` term is the load-bearing one — see the modifier's own comment.
    private var avatarLoadKey: String {
        [
            child?.id.uuidString ?? "-",
            child?.avatarKey ?? "-",
            avatarSync == nil ? "0" : "1",
        ].joined(separator: "|")
    }

    /// Local file first; a presigned GET only when there is no local copy and the server says
    /// there is something to get. Nil is the ordinary answer for a child with no avatar and is
    /// never surfaced as a failure.
    private func loadAvatar() async {
        guard let child, let avatarSync else {
            avatar = nil
            return
        }
        avatar = await avatarSync.avatarData(for: child.id, remoteKey: child.avatarKey)
    }

    /// A new photo. **The same two calls `OnboardingGate.finish(with:)` makes**, which is the
    /// point — the local write, the pending record and the sweep are `AvatarSync`'s, and Settings
    /// does not get a second upload path of its own.
    ///
    /// `avatar` is assigned here rather than left to `.task(id: avatarLoadKey)`. A replace does not
    /// move `child.avatarKey` until a commit lands and something refetches, so the key would not
    /// change, the task would not re-run, and the hero would keep drawing the old picture behind a
    /// sheet showing the new one.
    ///
    /// **The child and the sync are arguments rather than re-read from state**, because the caller
    /// — `ChildPhotoActions`, built where both are already unwrapped — has them. Re-guarding here
    /// would let the two disagree: the sheet could be showing a photo for a child this screen has
    /// since replaced.
    private func choosePhoto(_ jpeg: Data, child: ChildResponse, sync: AvatarSync) {
        sync.enqueue(jpeg, for: child.id)
        avatar = jpeg
        Task { await sync.sweep() }
    }

    /// Removing one. The local file and the pending record go together inside `AvatarSync.remove`;
    /// the server is told on the sweep. `avatar` is assigned here for the same reason as above —
    /// removing a photo that never committed does not move `avatarKey` either, because it is
    /// already nil.
    private func removePhoto(child: ChildResponse, sync: AvatarSync) {
        sync.remove(for: child.id)
        avatar = nil
        Task { await sync.sweep() }
    }

    /// Fold the saved child back into the row values without a refetch.
    private func apply(_ updated: ChildUpdateResponse) {
        guard let existing = child else { return }
        child = ChildResponse(
            id: existing.id,
            name: updated.name,
            birthdate: updated.birthdate,
            // From the response, not carried over from `existing`. `PATCH` returns the row it
            // wrote, so this is the one value on screen guaranteed to match the column —
            // including when the save cleared it back to unanswered.
            pronouns: updated.pronouns,
            // From the response for the same reason `pronouns` is: `PATCH` returns the row it
            // wrote. The edit sheet cannot change the avatar — `updateChild` omits `avatar_key`
            // entirely — but a save made while an upload was landing would otherwise put a stale
            // nil back on screen and hide an avatar that had just arrived.
            avatarKey: updated.avatarKey,
            familyTimezone: updated.familyTimezone,
            // Unchanged on purpose. `age_months` is the server's, `PATCH` does not return it,
            // and inventing one here would be the client deciding something it does not own.
            ageMonths: existing.ageMonths,
            role: existing.role
        )
        onTimezoneResolved(updated.familyTimezone)
        onPromptSubjectChanged(child?.promptSubject ?? .unknown)
    }


    /// The existing sweep, not a media-only path. **Entries drain before media** — a media
    /// upload against an entry the server has never seen spends an attempt on a guaranteed 404
    /// and pushes that file's backoff out for nothing.
    /// **Reaches `MediaCoordinator.shared`, and does not build a second one.** `sync` is the
    /// `EntrySync` `RootView` constructed with the process-wide coordinator — the same object it
    /// assigned to `MediaCoordinator.shared` — so the sweep here and a background upload callback
    /// are the same queue. A coordinator built locally would be a second uploader with its own
    /// in-flight set, racing the first for the same rows.
    ///
    /// **It says what happened.** A primary action that disables, re-enables, and reports nothing
    /// teaches the parent that the card is decorative — and this one is pressed at the moment
    /// somebody is worried about whether their photos are safe.
}
