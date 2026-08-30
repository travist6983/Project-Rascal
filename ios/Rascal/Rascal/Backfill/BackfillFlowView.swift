import SwiftData
import SwiftUI

/// The camera-roll flow, from the offer to a prefilled composer.
///
/// Presented full-screen from the **+** sheet. It owns its own composer presentation rather than
/// handing back up to `RootView`, because the design's Cancel returns to the month you were
/// picking from — a composer owned by the root would dismiss to Today and lose the place.
/// `onComposerDismiss` is how the root still gets its sweep.
struct BackfillFlowView: View {
    let childId: UUID
    /// Only for the age lines. Nil until the archive has told us one, which simply drops them.
    let childBirthdate: Date?
    /// The month the child was born in, and the floor under both browse lists.
    ///
    /// **Carried as a `BackfillMonth` rather than derived from `childBirthdate`.** That `Date` is
    /// parsed in the *device's* zone by `EditChildModel.dayFormatter`; reading its month back in the
    /// child's would put a child born on the 1st into the previous month for a family far enough
    /// east. `BackfillMonth(calendarDay:)` reads the year and month out of the `YYYY-MM-DD` string
    /// with no instant in between, which is the only version that cannot drift.
    let birthMonth: BackfillMonth?
    /// The child's `family_timezone`, for deciding what month it is. **Never `Calendar.current`.**
    let familyTimezone: String
    let api: APIClient
    let scanner: BackfillScanner
    let source: any BackfillAssetSource
    /// Read fresh rather than captured: an entry saved inside this flow changes what counts as an
    /// unlogged month, and a rescan on stale dates would re-offer a month just written.
    let entryDates: () -> [Date]
    let onComposerDismiss: () async -> Void

    @State private var path: [BackfillMonth] = []
    @State private var stage: Stage = .deciding
    @State private var composer: ComposerRequest?
    @State private var toast: BackfillToast?
    /// Built in `init` rather than in `.task`. Every grid in the flow reads it out of the
    /// environment non-optionally, so it has to exist before the first render, not after it.
    @State private var loader: BackfillThumbnailLoader
    /// Months saved during this visit, so the picker can check off what has just been written
    /// without waiting for a rescan.
    @State private var savedDays: Set<Date> = []
    /// The day a composer was just opened for, waiting to find out whether anything was written.
    @State private var pendingDay: Date?
    /// The month it is in the child's zone, read **once per presentation** rather than in `body`.
    ///
    /// A `Date()` inside a computed property is a different answer on every redraw, which on the
    /// stroke of midnight on the 1st would resort the screen under the parent's thumb. Read once,
    /// held, and left alone for the life of the flow.
    @State private var thisMonth: BackfillMonth?
    /// The grant every screen in this flow was last drawn under.
    ///
    /// **Held here rather than read off the scanner**, which is the same question asked of the
    /// wrong object: `scanner.authorization` is written by a *scan*, and the two stages that never
    /// scan — `.permission` and `.denied` — leave it at `.notDetermined` for as long as they are on
    /// screen. A reconcile comparing against that would think the grant had moved on every single
    /// foreground from the denied screen, which is the one screen a parent foregrounds onto after
    /// visiting Settings.
    @State private var routedGrant: BackfillAuthorization?
    /// True while a user-driven decision already owns the flow's routing.
    ///
    /// **The system permission alert takes the scene inactive and back to active**, and the gate
    /// above now matches `.active` — as it must — so a foreground can land in the middle of
    /// `grantAndScan` or `widenSelection`. Two forced scans cancel one another in
    /// `BackfillScanner.scan`, and whichever loses reads an `.idle` scanner and settles the flow on
    /// a false `.empty`. The parent's own tap is authoritative; a foreground arriving during it has
    /// nothing to add and must wait.
    @State private var isRouting = false
    /// A foreground reconcile that arrived while `isRouting` was held.
    ///
    /// **Owed, not dropped.** The guard exists so a foreground cannot fight the parent's own tap,
    /// but a *dropped* reconcile is a grant change nobody ever notices: the widen picker can be up
    /// across an app switch, and the next foreground compares against a `routedGrant` that by then
    /// matches, so the change is invisible until something else happens to re-route.
    @State private var reconcileOwed = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    /// **The only way this flow finds out that Settings happened.** See `reconcileAuthorization`.
    @Environment(\.scenePhase) private var scenePhase

    init(
        childId: UUID,
        childBirthdate: Date?,
        birthMonth: BackfillMonth?,
        familyTimezone: String,
        api: APIClient,
        scanner: BackfillScanner,
        source: any BackfillAssetSource,
        entryDates: @escaping () -> [Date],
        onComposerDismiss: @escaping () async -> Void
    ) {
        self.childId = childId
        self.childBirthdate = childBirthdate
        self.birthMonth = birthMonth
        self.familyTimezone = familyTimezone
        self.api = api
        self.scanner = scanner
        self.source = source
        self.entryDates = entryDates
        self.onComposerDismiss = onComposerDismiss
        _loader = State(initialValue: BackfillThumbnailLoader(source: source))
    }

    enum Stage: Equatable {
        case deciding
        case permission
        case scanning
        case suggestions
        case limited
        case denied
        case empty
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: BackfillMonth.self) { month in
                    BackfillMonthPickerScreen(
                        month: month,
                        // The picker cuts days and resolves `occurred_at` in the child's zone, not
                        // the phone's. Nothing else on this screen can supply it.
                        familyTimezone: familyTimezone,
                        source: source,
                        childBirthdate: childBirthdate,
                        savedDays: savedDays,
                        // Carried in so the month total does not read as a fact about the month
                        // when it is a fact about the selection.
                        isLimited: scanner.isLimitedLibrary,
                        onWidenSelection: scanner.isLimitedLibrary
                            ? { Task { await widenSelection() } }
                            : nil,
                        onUse: { plan, drafts, day in
                            // Recorded, **not** marked written. See `confirmWritten`.
                            pendingDay = day
                            composer = plan.composerRequest(
                                childId: childId,
                                drafts: drafts,
                                childBirthdate: childBirthdate
                            )
                        }
                    )
                }
        }
        .background(Color.canvas)
        .task { await decideStage() }
        // **A `.task` does not re-run on a foreground, and this flow had no other lifecycle hook.**
        // Both dead-end screens offer a button that leaves the app for Settings, so without this
        // the one remedy the design deliberately provides returns the parent to a screen still
        // saying access is off. See `reconcileAuthorization`.
        //
        // **`.active` alone, and never `previous == .background`.** iOS interposes `.inactive` on
        // the way back in — `TodayScreen.swift:286-288` writes down the same platform fact for the
        // opposite reason — so SwiftUI publishes `.background → .inactive` and then
        // `.inactive → .active` as two separate changes, and a guard wanting both halves at once
        // is never satisfied. Every other `scenePhase` observer in this app matches `.active`
        // alone; this one is not the exception it briefly was. `BackfillGrantChange.shouldReread`
        // holds the comparison so it is asserted rather than eyeballed.
        .onChange(of: scenePhase) { _, phase in
            guard BackfillGrantChange.shouldReread(phase) else { return }
            Task { await reconcileAuthorization() }
        }
        .environment(loader)
        .overlay(alignment: .bottom) {
            if let toast {
                BackfillToastView(toast: toast) { undo(toast) }
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $composer, onDismiss: {
            confirmWritten()
            Task {
                await onComposerDismiss()
                // The month just written is no longer unlogged. Rescanning on the way out keeps
                // the offer honest rather than leaving a month on the list the parent has now
                // filled — `force` because the cache would otherwise hand back the old answer.
                scanner.scan(entryDates: entryDates(), force: true)
            }
        }) { request in
            ComposerView(request: request, api: api)
        }
    }

    /// Check off a day only once something is actually in the store for it.
    ///
    /// **Marking it when the composer opened was wrong.** The composer dismisses on Cancel exactly
    /// as it does on Save, so a parent who picked three photos, thought better of it, and swiped
    /// the sheet away came back to a day badged "Written" with nothing behind it — the same class
    /// of lie as a completion check on a prompt with no entry. The store is the only thing that
    /// knows, so it is what gets asked.
    private func confirmWritten() {
        guard let day = pendingDay else { return }
        pendingDay = nil
        // The same calendar the picker cut `day` out of. Adding a day in the device's zone would
        // step a family-zone midnight by the device's DST, and the window would then either miss
        // the entry just written or reach into the next day.
        let calendar = BackfillCalendar.family(familyTimezone)
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return }
        // This child's entries only. The sibling having written something on this day would
        // otherwise badge it "Written" for a child who has nothing there — the same shape of lie
        // as a completion check on a prompt with no entry behind it.
        let child = childId
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate {
                $0.childId == child && $0.deletedAt == nil
                    && $0.occurredAt >= day && $0.occurredAt < next
            }
        )
        descriptor.fetchLimit = 1
        if let count = try? context.fetchCount(descriptor), count > 0 {
            savedDays.insert(day)
        }
    }

    @ViewBuilder
    private var root: some View {
        switch stage {
        case .deciding:
            // One frame at most, while the authorization status is read. Canvas rather than a
            // spinner: something that appears for 16ms and vanishes reads as a flicker.
            Color.canvas.ignoresSafeArea()
        case .permission:
            BackfillPermissionScreen(onAgree: { await grantAndScan() }, onCancel: { dismiss() })
        case .scanning:
            BackfillScanningScreen(onCancel: { scanner.cancel(); dismiss() })
        case .suggestions:
            suggestions
        case .limited:
            BackfillLimitedAccessScreen(
                visibleCount: scanner.months.reduce(0) { $0 + $1.assetCount },
                onContinue: { stage = .suggestions },
                onWiden: { Task { await widenSelection() } },
                onClose: { dismiss() }
            )
        case .denied:
            BackfillNoAccessScreen(onClose: { dismiss() })
        case .empty:
            BackfillNothingToSuggestScreen(
                onBrowse: { stage = .suggestions },
                onClose: { dismiss() }
            )
        }
    }

    /// `SUGGESTED`: this month, in the years before it.
    ///
    /// Built from `scanner.months` — the index the scan already produced and holds — so nothing
    /// here issues a fetch. Five candidates filtered three ways is arithmetic over at most a few
    /// hundred structs, which is why it can sit in a computed property without a cache of its own.
    private var suggestedMonths: [BackfillMonthSummary] {
        guard let thisMonth else { return [] }
        let wanted = BackfillPlan.suggested(
            thisMonth: thisMonth,
            birthMonth: birthMonth,
            photoCounts: BackfillPlan.photoCounts(scanner.months),
            dismissed: scanner.dismissedMonths
        )
        // Ordered by the rule, not by the index: `suggested` returns most recent first and that is
        // the order the cards read in. A lookup keeps each month's real count rather than
        // re-deriving one.
        let byMonth = Dictionary(scanner.months.map { ($0.month, $0) }, uniquingKeysWith: { a, _ in a })
        return wanted.compactMap { byMonth[$0] }
    }

    private var browsableMonths: [BackfillMonthSummary] {
        guard let thisMonth else { return scanner.months }
        return BackfillPlan.browsable(scanner.months, birthMonth: birthMonth, thisMonth: thisMonth)
    }

    private var suggestions: some View {
        BackfillSuggestionsScreen(
            suggested: suggestedMonths,
            months: browsableMonths,
            childBirthdate: childBirthdate,
            // **Carried through, so no count on that screen reads as a complete one.** Under
            // `.limited` every month total is computed over the shared selection, which is wrong
            // while looking entirely normal.
            isLimited: scanner.isLimitedLibrary,
            onWidenSelection: scanner.isLimitedLibrary ? { Task { await widenSelection() } } : nil,
            onOpen: { path.append($0) },
            onDismissMonth: { setAside($0) },
            onClose: { dismiss() }
        )
    }

    /// Add more photos to the selection, then count again.
    ///
    /// The rescan is `force`, because the selection changing is exactly the case a cached result
    /// is wrong about — and it is the whole reason the parent tapped.
    private func widenSelection() async {
        await asRouting {
            await LimitedLibraryPicker.present()
            // **Before the rescan, and this line is the whole fix.** The forced rescan refreshes
            // the month totals; the photos those totals count are read through the loader, whose
            // per-month memo had no invalidation path at all. Without this the card's number grew
            // while its thumbnails stayed pre-widen, and opening the month showed the old grid
            // under the new count — the affordance appearing to do nothing, in the one state it
            // exists for.
            loader.forgetAssets()
            await scanner.scanAndWait(entryDates: entryDates(), force: true)
        }
    }

    /// Hold the flow's routing for the length of one user-driven decision, then honour any
    /// foreground reconcile that arrived while it was held.
    ///
    /// **The draining half is the point.** Guarding alone stops a foreground fighting the parent's
    /// own tap, and then silently loses the one foreground that mattered — the widen picker can be
    /// up across an app switch, and by the next foreground `routedGrant` matches again, so the
    /// change is invisible until something else happens to re-route.
    private func asRouting(_ body: () async -> Void) async {
        isRouting = true
        await body()
        isRouting = false
        if reconcileOwed {
            reconcileOwed = false
            await reconcileAuthorization()
        }
    }

    private var readyClusters: [BackfillCluster] {
        if case .ready(let clusters) = scanner.state { return clusters }
        return []
    }

    // MARK: Stage

    /// Which screen this flow opens on.
    ///
    /// Reads the authorization status rather than assuming: the parent may have granted access on
    /// a previous visit, revoked it in Settings since, or narrowed it to a selection. Each of those
    /// has a different first screen and none of them is the system prompt.
    private func decideStage() async {
        // Read once, here, before any screen exists — in the child's zone and not the phone's. A
        // device in Auckland and a family timezone of Los Angeles disagree about what month it is
        // for up to a day, and on the 1st that disagreement is a whole month of cards.
        thisMonth = BackfillCalendar.month(containing: Date(), in: familyTimezone)
        await asRouting { await route(force: false) }
    }

    /// The grant may have changed while the parent was in Settings.
    ///
    /// **Scoped to a status that actually moved**, rather than re-deciding on every foreground: a
    /// parent who switched apps to answer a message comes back to the month they were in with
    /// their selection intact, which is the ordinary case and must stay cheap. Only a grant that
    /// is different from the one every screen was drawn under earns a rebuild.
    ///
    /// It handles both directions, and the second is the one that is easy to forget. Granting in
    /// Settings unfreezes the dead end. **Revoking or narrowing in Settings leaves a grid of
    /// photographs the app can no longer read**, which is worse than a dead end because nothing on
    /// screen looks wrong.
    ///
    /// `thisMonth` is deliberately not re-read. It is the month in the child's zone, held for the
    /// life of the presentation so the screen cannot resort itself under the parent's thumb at
    /// midnight on the 1st — a foreground is not a reason to break that.
    private func reconcileAuthorization() async {
        guard !isRouting else { reconcileOwed = true; return }
        let current = await source.authorization()
        let effect = BackfillGrantChange.effect(was: routedGrant, now: current)
        guard effect != .none else { return }
        // **`.rescan` never touches `stage` or `path`, and that is the whole distinction.** The
        // grant has not changed *kind* — only which photos may be behind it — so every screen the
        // parent is standing on is still the right screen. Routing here would re-derive `stage`
        // from the grant alone and march a `.limited` parent back to the interstitial they
        // dismissed with "Continue with these", flashing the scanning screen on the way, on every
        // single foreground.
        //
        // **And the grid is only torn down if the photographs actually moved.** `forgetAssets()`
        // bumps the generation both grids key their `.task` on, so calling it unconditionally here
        // would blank an open month to a spinner and dump every decoded thumbnail — every time a
        // notification banner, Control Center, the app switcher or an incoming call took the scene
        // through `.inactive`. That is the same "ejected on every foreground" defect this branch
        // exists to prevent, moved from `stage` into the loader.
        //
        // **`loader.revalidate()` asks the library, and that is the point.** Comparing
        // `scanner.months` across the rescan looked like the cheap answer and was the wrong
        // question twice over: a month summary is three integers, so a selection edit that swaps
        // one October photo for another is invisible to it, and `entryCount` moves when the
        // archive gains an entry, which is not a camera-roll change at all.
        guard effect != .rescan else {
            // **The month *index* is re-counted only under `.limited`.** There, the counts on
            // every screen are counts of a selection the parent may have just edited in Settings,
            // and they are small. Under full access the same forced rescan is a walk of forty
            // thousand assets on every return to the app, which is the cost this feature has
            // avoided everywhere else; its 24-hour cache already governs that index.
            if current == .limited {
                await scanner.scanAndWait(entryDates: entryDates(), force: true)
            }
            // **This runs under every readable grant.** It only touches months already on screen,
            // and returns immediately when none is — a parent who has not opened a month pays
            // nothing for it.
            await loader.revalidate()
            return
        }

        // Everything on screen was read under a grant that no longer applies, and the loader's
        // per-month memo has no other invalidation point.
        loader.forgetAssets()

        // The grant changed kind, so the screen chosen for the old one is the wrong screen.
        // **Only a narrowing also pops the month.** Widening is the case where there is now *more*
        // to see in the month the parent is standing in, and throwing away a half-made one-day
        // selection to tell them so would be the app taking the decision away.
        if effect == .rebuild { path.removeAll() }
        await route(force: true)
    }

    /// Which screen the current authorization calls for.
    ///
    /// `force` is what separates arriving here from returning here. On arrival the cache is
    /// allowed to do its job; after a grant change it must not, because the cached index describes
    /// a library the app no longer has the same view of.
    private func route(force: Bool) async {
        // Read once and remembered, so `reconcileAuthorization` compares against what was actually
        // drawn rather than asking the library a second question it has already answered.
        let granted = await source.authorization()
        routedGrant = granted
        switch granted {
        case .notDetermined:
            stage = .permission
        case .denied:
            stage = .denied
        case .limited:
            // Scan **then** settle the stage. Setting `.limited` first and scanning afterwards
            // left the screen on `.scanning` forever, because `rescanIfNeeded` sets that stage and
            // has no terminal one to return to.
            await rescanIfNeeded(force: force)
            stage = .limited
        case .authorized:
            await rescanIfNeeded(force: force)
            stage = readyClusters.isEmpty ? .empty : .suggestions
        }
    }

    /// The offer on the **+** sheet came from a scan that has already run, so this is usually a
    /// no-op. It matters on the path where the parent has just granted access and there is
    /// nothing yet.
    /// `force` skips the early return as well as the cache. A grant that has just changed is
    /// exactly the case where `.ready` holds an answer about a library the app no longer sees the
    /// same way, so "already ready" is not a reason to keep it.
    private func rescanIfNeeded(force: Bool = false) async {
        if !force, case .ready = scanner.state { return }
        stage = .scanning
        await scanner.scanAndWait(entryDates: entryDates(), force: force)
    }

    private func grantAndScan() async {
        await asRouting { await performGrantAndScan() }
    }

    private func performGrantAndScan() async {
        let granted = await scanner.requestAccess()
        // The explainer's grant is a routing decision like any other, and the reconcile compares
        // against this. Without it a parent who grants here, backgrounds, and returns is told the
        // grant moved when nothing did.
        routedGrant = granted
        guard granted.canScan else {
            stage = .denied
            return
        }
        stage = .scanning
        // `force`, because access has just changed: a cached result from a previous grant — or
        // from a narrower one — is not an answer about what is visible now.
        await scanner.scanAndWait(entryDates: entryDates(), force: true)
        if granted == .limited {
            stage = .limited
        } else {
            stage = readyClusters.isEmpty ? .empty : .suggestions
        }
    }

    // MARK: Setting a month aside

    /// "Not this one."
    ///
    /// Persisted immediately rather than after the toast expires — a force quit inside those few
    /// seconds should leave the month set aside, which is what the parent asked for. Undo is a
    /// restore, not a delayed commit.
    private func setAside(_ month: BackfillMonth) {
        scanner.dismiss(month)
        withAnimation(Motion.tap) {
            toast = BackfillToast(
                month: month,
                text: "Set aside — it's still in Every month.",
                canUndo: true
            )
        }
    }

    private func undo(_ toast: BackfillToast) {
        scanner.restore(toast.month, entryDates: entryDates())
        withAnimation(Motion.tap) { self.toast = nil }
    }
}

// MARK: - The toast

struct BackfillToast: Equatable, Identifiable {
    let month: BackfillMonth
    let text: String
    let canUndo: Bool

    var id: String { month.key }
}

/// Ink-on-cream inverted, the one place in the flow that is. It has to read over a scrolling grid.
struct BackfillToastView: View {
    let toast: BackfillToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text)
                .typeRole(.body)
                .foregroundStyle(Color.canvas)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if toast.canUndo {
                Button("Undo", action: onUndo)
                    .typeRole(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.terracottaSoft)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.ink, in: RoundedRectangle(cornerRadius: Layout.quoteBlockRadius, style: .continuous))
    }
}

// MARK: - The gradient beats

extension LinearGradient {
    /// `#FDE8DC → #F7DDE8 → #FBF6EF`, per `docs/design-system.md`.
    ///
    /// Reserved for emotional beats. In this flow that is the invitation, the all-caught-up state,
    /// and the header of a month being looked back at — an onboarding moment, an all-caught-up
    /// moment, and a throwback header. Never behind a list.
    ///
    /// **`Gradients.wash` itself, not a copy of its stops.** The doc says these two "are the same
    /// gradient and there is no third", and a second list of the same three literals is a promise
    /// kept by hand — one that quietly stops being true the first time the wash is retuned. This
    /// name stays because the flow reads better for it; the colours come from the palette.
    static let backfillWash = Gradients.wash
}

// MARK: - Permission

/// The explainer that earns the system prompt.
///
/// **iOS asks once.** A cold prompt on a screen the parent did not ask for is how this feature
/// gets denied permanently, and there is no second ask — the app deliberately does not build one.
/// So the three bullets are here, they are accurate to what the scan actually does, and "Not now"
/// leaves without asking anything.
struct BackfillPermissionScreen: View {
    let onAgree: () async -> Void
    let onCancel: () -> Void

    @State private var asking = false

    private let bullets = [
        "Only the dates and how many photos — never the pictures themselves.",
        "Everything stays on this phone. Nothing is uploaded.",
        "You pick what becomes an entry. Nothing is added on its own.",
    ]

    /// **Scrolls, and the actions are pinned.**
    ///
    /// This screen was a `VStack` of spacers in a full-height frame. At the accessibility text
    /// sizes the headline ran off the top and *both buttons ran off the bottom* — so the one
    /// screen whose entire job is asking for permission had no reachable way to grant it, and iOS
    /// only asks once. Content scrolls; the actions live in a bottom inset that cannot be pushed
    /// anywhere.
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                PhotoStackMotif()
                VStack(spacing: 14) {
                    Text("There's a lot in there already")
                        .typeRole(.display)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text("Pocket Chronicle can look through your photos to find months worth writing about.")
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                }
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.sageInk)
                                .frame(width: 22, height: 22)
                                .background(Color.sage, in: Circle())
                            Text(bullet)
                                .typeRole(.body)
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Layout.screenMargin)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient.backfillWash.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Button("Look through my photos") {
                    asking = true
                    Task { await onAgree(); asking = false }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(asking)

                Button("Not now", action: onCancel)
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
            .padding(.horizontal, Layout.screenMargin)
            // Enough room for the backdrop's fade to actually fade. At 12 the gradient had no
            // height to work in and body text collided with the button's top edge.
            .padding(.top, 26)
            .padding(.bottom, 18)
            .background(PinnedActionBackdrop(tint: .washTail))
        }
    }
}

/// The backdrop behind a pinned action bar: opaque where the buttons are, fading upward so
/// content scrolling underneath does not collide with them.
///
/// **Named for what it does, not for where it was born.** It started as backfill's, and Phase 20
/// gave `OnboardingStepScaffold` the same pinned-footer treatment — at which point every
/// onboarding screen in the app depended on a type whose name said "backfill", which is the kind
/// of thing that reads as an accident and gets copy-pasted into a second one.
struct PinnedActionBackdrop: View {
    var tint: Color = .canvas

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(0), tint, tint],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// Three drifted rectangles standing in for a stack of prints. No photo is shown — nothing has
/// been granted yet, and illustrating this screen with the library would be showing what it is
/// asking permission to see.
struct PhotoStackMotif: View {
    var body: some View {
        ZStack {
            card(fill: Color.surface, rotation: -9, offset: CGSize(width: -36, height: 4))
            card(fill: Color.printWarm, rotation: 4, offset: CGSize(width: -8, height: -4))
            card(fill: Color.sageBorder, rotation: 11, offset: CGSize(width: 22, height: 8))
        }
        .frame(width: 150, height: 120)
        .accessibilityHidden(true)
    }

    private func card(fill: Color, rotation: Double, offset: CGSize) -> some View {
        RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            .frame(width: 96, height: 80)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .shadow(color: .ink.opacity(0.05), radius: 4, y: 2)
    }
}

// MARK: - Scanning

struct BackfillScanningScreen: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            PhotoStackMotif()
                .padding(.bottom, 34)
            Text("Looking through your photos")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text("This all happens on your phone.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .padding(.top, 8)
            ProgressView()
                .tint(Color.terracotta)
                .padding(.top, 24)
            Spacer()
            Button("Cancel", action: onCancel)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.inkMuted)
        }
        .padding(Layout.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Looking through your photos. This all happens on your phone.")
    }
}

// MARK: - Limited, denied, empty

/// Selected-photos access. **Not an error state.**
///
/// The parent made a deliberate, reasonable choice and the screen says what the app can see rather
/// than treating it as a failure to be recovered from. "Continue with these" is the primary action
/// because continuing is genuinely fine.
struct BackfillLimitedAccessScreen: View {
    let visibleCount: Int
    let onContinue: () -> Void
    /// Widen the selection, in the app.
    ///
    /// **This is the first screen a `.limited` parent lands on and it had no way to share more
    /// photos** — only "Continue with these" and a button that leaves for Settings, which is the
    /// slower route to a narrower outcome: Settings can grant full access, but the in-app picker
    /// is the thing that actually adds photos, and it can be opened any number of times.
    var onWiden: (() -> Void)?
    let onClose: () -> Void

    // Scrolls with the actions pinned, for the reason `BackfillPermissionScreen` documents.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackfillCloseButton(action: onClose)
                    .padding(.bottom, 24)

                HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .fill(Color.printWarm)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .fill(Color.periwinkleBorder)
                    .frame(width: 76, height: 76)
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                        .strokeBorder(Color.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: 76, height: 76)
                    }
                }
                .accessibilityHidden(true)
                .padding(.bottom, 22)

                Text(headline)
                    .typeRole(.detailTitle)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You chose which photos to share, so those are the only ones here. Suggestions will be thin until more are shared — that's fine, and you can change it whenever.")
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            .padding(Layout.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button("Continue with these", action: onContinue)
                    .buttonStyle(PrimaryButtonStyle())
                // Settings drops to inline text here rather than keeping the bordered button, so
                // the in-app picker is the visibly easier of the two. Both stay reachable: the
                // picker widens a selection, and Settings is the only place full access lives.
                HStack(spacing: 16) {
                    if let onWiden {
                        Button("Share more photos", action: onWiden)
                            .typeRole(.cardTitle)
                            .foregroundStyle(Color.terracotta)
                    }
                    SettingsLinkText()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .padding(.horizontal, Layout.screenMargin)
            // Enough room for the backdrop's fade to actually fade. At 12 the gradient had no
            // height to work in and body text collided with the button's top edge.
            .padding(.top, 26)
            .padding(.bottom, 18)
            .background(PinnedActionBackdrop())
        }
    }

    private var headline: String {
        visibleCount == 1
            ? "Pocket Chronicle can see 1 of your photos"
            : "Pocket Chronicle can see \(visibleCount) of your photos"
    }
}

/// Access refused, or revoked in Settings since the last visit.
///
/// Not in the mockups, and necessary: without it the flow dead-ends on a blank screen for anyone
/// who has ever tapped Don't Allow. There is no retry funnel here on purpose — iOS will not show
/// its prompt again, so the only honest thing to offer is Settings.
struct BackfillNoAccessScreen: View {
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackfillCloseButton(action: onClose)
                    .padding(.bottom, 30)
                Text("Pocket Chronicle can't see your photos")
                    .typeRole(.detailTitle)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Photo access is off, so there's nothing to look through. Everything else works exactly as it did.")
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            .padding(Layout.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom) {
            SettingsLinkButton()
                .padding(.horizontal, Layout.screenMargin)
                .padding(.top, 26)
                .padding(.bottom, 18)
                .background(PinnedActionBackdrop())
        }
    }
}

/// Every month with photos has something written in it. **A success, and it reads as one.**
struct BackfillNothingToSuggestScreen: View {
    let onBrowse: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackfillCloseButton(action: onClose)
                    .padding(.bottom, 30)
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.sageInk)
                    VStack(spacing: 14) {
                        Text("You've written about every month that has photos")
                            .typeRole(.detailTitle)
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.center)
                        Text("Nothing waiting. You can still wander back through any month.")
                            .typeRole(.body)
                            .foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Layout.screenMargin)
        }
        .background(LinearGradient.backfillWash.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button("Browse every month", action: onBrowse)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Layout.screenMargin)
                .padding(.top, 26)
                .padding(.bottom, 18)
                .background(PinnedActionBackdrop(tint: .washTail))
        }
    }
}

/// Opens the app's own page in Settings, which is the only place photo access can be changed.
struct SettingsLinkButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings") {
            #if canImport(UIKit)
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            #endif
        }
        .typeRole(.cardTitle)
        .foregroundStyle(Color.inkMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
    }
}

/// The circular back affordance the flow's full-screen states use.
struct BackfillCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 38, height: 38)
                .background(Color.surface, in: Circle())
                .overlay(Circle().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel("Back")
    }
}

// MARK: - Reconciling a grant

/// Whether a foreground changes what the camera-roll flow may show, and what to do about it.
///
/// **Lifted out of the view because the mistake it prevents is invisible and the code is one
/// comparison.** The first version of this gate read `previous == .background, current == .active`,
/// which is a transition the UIScene lifecycle never delivers in one step, so the reconcile it
/// guarded was dead on arrival — a fix that compiled, shipped, and did nothing. Nothing on screen
/// would have said so, and no model-level test could reach it. Here it is arithmetic, and asserted.
nonisolated enum BackfillGrantChange {

    /// Whether this scene phase is the moment to re-read the grant.
    ///
    /// `.active` alone. iOS delivers `.inactive` between `.background` and `.active`, and also on
    /// its own for a pulled-down notification, Control Center, the app switcher, a screenshot and
    /// an incoming call — so `.active` is the only phase that reliably means "the parent is looking
    /// at this again", and it is what every other observer in the app matches.
    static func shouldReread(_ phase: ScenePhase) -> Bool { phase == .active }

    /// What a grant moving from `was` to `now` means for what is already on screen.
    ///
    /// **Three outcomes, not two, and the split between the first two is the one that matters.**
    /// "The library changed" and "the kind of access changed" call for different things: the first
    /// is new data under a screen that is still correct, the second is a screen that has stopped
    /// being the right screen. Collapsing them re-routes on a data change and ejects the parent
    /// from wherever they had got to.
    enum Effect: Equatable {
        /// Nothing the parent can see has changed. The ordinary foreground, and the common case.
        case none
        /// Re-read the library and **change nothing else**. Same kind of access, possibly different
        /// photographs behind it; every screen the parent is on is still the right one.
        case rescan
        /// The grant widened. Re-decide which screen this flow belongs on — the one showing was
        /// chosen for a grant that no longer applies — but keep the month they had pushed.
        case reroute
        /// The grant narrowed. Re-decide, and leave the month as well: the photographs behind it
        /// may be gone, and a grid of pictures the app can no longer read is worse than a dead
        /// end, because nothing about it looks wrong.
        case rebuild
    }

    static func effect(was: BackfillAuthorization?, now: BackfillAuthorization) -> Effect {
        // Nothing has been drawn yet, so there is nothing to reconcile against. The flow's `.task`
        // owns the first routing decision and this must not race it.
        guard let was else { return .none }
        if was == now {
            // **A library moves under any grant that can read it, not only a selected one.** The
            // first version of this said `.limited` and reasoned about *selection* edits — which
            // was the case in front of it and not the general one. A date corrected in Photos'
            // Adjust Date & Time and an original pulled down from iCloud are grant-independent,
            // and the first of those reaches `occurred_at`, the single error this whole feature
            // exists to prevent. Scoping the re-read to `.limited` left the most common grant,
            // full access, with no invalidation at all for the life of the flow.
            //
            // It stays a re-read and never a re-route: nothing about the parent's place on screen
            // has stopped being true.
            return now.canScan ? .rescan : .none
        }
        return visibility(now) < visibility(was) ? .rebuild : .reroute
    }

    /// How much of the library a grant lets the app see. Ordering only — the numbers mean nothing
    /// beyond "fewer photos than".
    private static func visibility(_ grant: BackfillAuthorization) -> Int {
        switch grant {
        case .authorized: 3
        case .limited: 2
        case .notDetermined: 1
        case .denied: 0
        }
    }
}
