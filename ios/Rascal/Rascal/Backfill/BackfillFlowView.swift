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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

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
        await LimitedLibraryPicker.present()
        await scanner.scanAndWait(entryDates: entryDates(), force: true)
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

        switch await source.authorization() {
        case .notDetermined:
            stage = .permission
        case .denied:
            stage = .denied
        case .limited:
            // Scan **then** settle the stage. Setting `.limited` first and scanning afterwards
            // left the screen on `.scanning` forever, because `rescanIfNeeded` sets that stage and
            // has no terminal one to return to.
            await rescanIfNeeded()
            stage = .limited
        case .authorized:
            await rescanIfNeeded()
            stage = readyClusters.isEmpty ? .empty : .suggestions
        }
    }

    /// The offer on the **+** sheet came from a scan that has already run, so this is usually a
    /// no-op. It matters on the path where the parent has just granted access and there is
    /// nothing yet.
    private func rescanIfNeeded() async {
        if case .ready = scanner.state { return }
        stage = .scanning
        await scanner.scanAndWait(entryDates: entryDates())
    }

    private func grantAndScan() async {
        let granted = await scanner.requestAccess()
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
                    Text("Vellum can look through your photos to find months worth writing about.")
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
                SettingsLinkButton()
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
            ? "Vellum can see 1 of your photos"
            : "Vellum can see \(visibleCount) of your photos"
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
                Text("Vellum can't see your photos")
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
