import SwiftUI

/// One month, grouped by day, with a selection confined to a single one of them.
///
/// **The one-day rule is a date guarantee, not a UI preference.** `BackfillDateRule` resolves a
/// selection to its earliest plausible creation date, so a selection spread across three weeks
/// produces a date that is defensible and not accurate — the entry lands on the first of the three
/// weeks and says nothing about the rest. Confining the selection to one day makes the resolved
/// date *exact*, which is the whole reason this feature is careful about `occurred_at` at all.
///
/// Nothing is preselected. Choosing photos on the parent's behalf, in the one flow whose purpose is
/// getting the date right, would be the app deciding what a day was about.
struct BackfillMonthPickerScreen: View {
    let month: BackfillMonth
    /// The child's `family_timezone`. **Never `Calendar.current`** — see `BackfillCalendar`.
    ///
    /// Every date decision on this screen is made in it: which day a photo groups under, what the
    /// day headers are named, and the `occurred_at` the plan resolves. Without it a photo with no
    /// capture date fell back to noon on the 1st *in the device's zone*, and a parent in Auckland
    /// filling a Los Angeles archive is twenty hours away from that — far enough that noon on the
    /// 1st of October is the 30th of September in the archive, permanently.
    let familyTimezone: String
    let source: any BackfillAssetSource
    let childBirthdate: Date?
    /// Days written during this visit, checked off without waiting for a rescan.
    let savedDays: Set<Date>
    /// Selected-photos access. **The month total in the subtitle is a count of what the app can
    /// see**, and under `.limited` that is the shared selection rather than the month — so it says
    /// which. The grid below is self-describing (the photos are right there); a total above it is
    /// not, and reads as a fact about the month.
    var isLimited: Bool = false
    /// Widen the selection, from the screen where a missing photo is most visible.
    ///
    /// **This grid is where a parent notices photos are absent** — the suggestions screen shows
    /// four tiles and a total, this one shows the month — and it was the one screen in the flow
    /// with no way to act on that. Nil where there is nothing to widen.
    var onWidenSelection: (() -> Void)?
    let onUse: (BackfillEntryPlan, [MediaDraft], Date) -> Void

    @Environment(BackfillThumbnailLoader.self) private var loader
    /// The device's pixels-per-point. `PHImageManager` wants pixels, and asking in points gets a
    /// third of the picture back on a 3× phone.
    @Environment(\.displayScale) private var displayScale

    @State private var days: [DayGroup] = []
    @State private var loading = true
    /// The one-day rule lives in `BackfillSelection`, not in this view — see that type.
    @State private var selection = BackfillSelection()
    @State private var staging = false
    @State private var notice: String?
    /// The screen's own width, for the tile arithmetic.
    ///
    /// Seeded rather than started at zero, the way `AddToArchiveSheet` seeds its height: the real
    /// value lands in the same layout pass, and a zero-width first frame would ask PhotoKit for
    /// 1×1 thumbnails and then throw them away.
    @State private var contentWidth: CGFloat = 393

    private let staged = StagingStore()

    /// The one calendar this screen reads dates in, derived once from the family zone so the day a
    /// photo is filed under and the date resolved from that day are the same answer.
    private var calendar: Calendar { BackfillCalendar.family(familyTimezone) }

    /// One tile's side, in points. Whole points — see `BackfillGrid.tileSide`.
    private var tileSide: CGFloat {
        BackfillGrid.tileSide(forWidth: contentWidth, margin: Layout.screenMargin)
    }

    /// What the grid asks PhotoKit for, in pixels.
    private var tilePixelSize: Int {
        BackfillGrid.pixelSize(forTileSide: tileSide, scale: displayScale)
    }

    struct DayGroup: Identifiable, Equatable {
        let day: Date
        let assets: [BackfillAsset]
        var id: Date { day }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                if isLimited {
                    // The same notice the suggestions screen carries, deliberately not a second
                    // wording of it: one moment, one sentence, wherever the parent meets it.
                    LimitedLibraryNotice(onWiden: onWidenSelection)
                        .padding(.horizontal, Layout.screenMargin)
                        .padding(.top, 16)
                }
                if loading {
                    ProgressView()
                        .tint(Color.terracotta)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if days.isEmpty {
                    Text("Nothing in this month is on the phone to add.")
                        .typeRole(.body)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, Layout.screenMargin)
                        .padding(.top, 30)
                } else {
                    ForEach(days) { group in
                        Section {
                            dayGrid(group)
                        } header: {
                            dayHeader(group)
                        }
                    }
                }
            }
            // **`safeAreaInset` already insets the scroll content by the pill's height** — that is
            // what it is for — so the old hardcoded 110 was a second inset stacked on the first,
            // and 40/110 changed the content's length the moment a photo was picked. What the pill
            // genuinely needs beyond its own height is the 16 of breathing room under the last row,
            // and the measured height is what keeps that true at the accessibility text sizes,
            // where the pill is half again as tall as the number 110 ever assumed.
            .padding(.bottom, selection.isEmpty ? 40 : 16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .background(Color.canvas)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { useButton }
        }
        // The generation is in the key for the reason `BackfillMonthThumbnailStrip` documents: a
        // month's key is invariant, so widening the selection while this grid is open could not
        // otherwise reach it.
        .task(id: "\(month.key)#\(loader.generation)") { await load() }
        // A caching manager still holding a month's photos keeps them decoded for the life of the
        // process, and the parent has left the picker.
        .onDisappear { loader.stopCachingEverything() }
        .overlay(alignment: .top) {
            if let notice {
                Text(notice)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(
                        Color.terracottaSoft,
                        in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    )
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.top, 60)
                    // Clears itself. Nothing was lost — the photo is still in the library — so a
                    // message that has to be dismissed would be treating a non-event as an alert.
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        if !Task.isCancelled { self.notice = nil }
                    }
            }
        }
    }

    // MARK: Header

    /// A throwback header, which is one of the beats `docs/design-system.md` reserves the gradient
    /// for. The month is the thing being looked back at.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One `Text` rather than two boxed side by side — see `BackfillMonthCard.monthTitle`.
            // The failure is worse here, at display size.
            (
                Text(month.monthName()).foregroundStyle(Color.ink)
                    + Text(" " + String(month.year)).foregroundStyle(Color.inkFaint)
            )
            .typeRole(.display)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 60)
            Text(subtitle)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.screenMargin)
        .padding(.bottom, 22)
        .background(LinearGradient.backfillWash)
    }

    private var subtitle: String {
        let count = days.reduce(0) { $0 + $1.assets.count }
        var parts = [count == 1 ? "1 photo" : "\(count) photos"]
        if isLimited { parts[0] += " you've shared" }
        // Neutrally worded — new client copy does not assume a gender. `DraftAge` because a month
        // with nothing written in it has no server-computed age to render.
        if let childBirthdate, childBirthdate <= month.fallbackDate() {
            parts.append(DraftAge.spoken(from: childBirthdate, to: month.fallbackDate()))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Days

    /// The pinned day header.
    ///
    /// It always had an opaque `canvas` fill spanning the content width, so the reported "renders
    /// with no background" was not what put photographs across it — an overflowing tile was, and
    /// that is fixed in `BackfillThumbnail`. **`.zIndex(1)` is kept anyway**, because a pinned
    /// header and the rows sliding under it are siblings in one stack, and leaving their paint
    /// order to be inferred is how this comes back. The vocabulary is `DayHeader`'s — bold day,
    /// lighter month, count in `inkMuted` — with **no periwinkle age capsule**: this is a picker,
    /// and the age belongs to the timeline where the entry lands.
    private func dayHeader(_ group: DayGroup) -> some View {
        let zone = calendar.timeZone
        return HStack(spacing: 10) {
            (
                Text(Self.dayNumber(group.day, in: zone)).fontWeight(.bold).foregroundStyle(Color.ink)
                    + Text(" " + Self.dayMonth(group.day, in: zone)).foregroundStyle(Color.inkMuted)
            )
            .typeRole(.cardTitle)
            Text(group.assets.count == 1 ? "1 photo" : "\(group.assets.count) photos")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
            Spacer(minLength: 4)
            if savedDays.contains(group.day) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("Written")
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(Color.sageInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.sage, in: Capsule())
            }
        }
        .padding(.horizontal, Layout.screenMargin)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvas)
        .zIndex(1)
        .accessibilityAddTraits(.isHeader)
    }

    /// One day's contact sheet.
    ///
    /// Columns are `.fixed(tileSide)` rather than `.flexible()`: the tile's rect is arithmetic —
    /// `BackfillGrid.tileSide` — and the same number decides the frame, the corner radius's context
    /// and the pixel size asked of PhotoKit. Flexible columns would let the grid resolve a width
    /// this view then has to guess at when sizing the request.
    ///
    /// **Identified by `PHAsset.localIdentifier`, never by index** — `BackfillAsset.id` is that
    /// identifier. An index-keyed tile recycles its `@State` into a different photograph when the
    /// day's contents shift, which is a picture appearing under someone else's checkmark.
    @ViewBuilder
    private func dayGrid(_ group: DayGroup) -> some View {
        if selection.blockedDay == group.day { oneDayNote(group.day) }

        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(tileSide), spacing: BackfillGrid.gutter),
                count: BackfillGrid.columns
            ),
            // `.leading`, because `.fixed` columns do not consume the leftover width and the grid's
            // own alignment decides where the slack goes. It is under a point at every phone width,
            // but a centred grid puts that half-point between the tiles and the screen margin the
            // day header is aligned to, and "under a point" is not the same as stated.
            alignment: .leading,
            spacing: BackfillGrid.gutter
        ) {
            ForEach(group.assets) { asset in
                tile(asset, in: group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.screenMargin)
        .padding(.bottom, 14)
        // The caching window, at the granularity the list already mounts in. `PHCachingImageManager`
        // decodes ahead on its own queue, and a `LazyVStack` mounts a section shortly before it is
        // reached — so the day the parent is scrolling towards is warm by the time it arrives, and
        // the one behind them is released rather than held for the life of the screen.
        //
        // The window is named rather than described: the loader stops it with the size it was
        // started with, because `tilePixelSize` can change between these two calls.
        .onAppear {
            loader.startCaching(
                group.assets.map(\.id), pixelSize: tilePixelSize, forWindow: group.id.description
            )
        }
        .onDisappear { loader.stopCaching(forWindow: group.id.description) }
    }

    /// One photograph, and whether it is picked.
    ///
    /// **The whole tile is the tap target**, not the circle. One-handed use is the constraint here,
    /// and a 26pt target inside a ~118pt tile is a dart board. The circle reports; the tile acts.
    private func tile(_ asset: BackfillAsset, in group: DayGroup) -> some View {
        let isSelected = selection.contains(asset)
        return Button {
            tap(asset, in: group)
        } label: {
            BackfillThumbnail(
                asset: asset,
                cornerRadius: BackfillGrid.cornerRadius,
                pixelSize: tilePixelSize
            )
            // The frame is the fix. A 9:16 asset and a 16:9 asset land in identical rects because
            // the rect is stated here and the picture is clipped to it, rather than being whatever
            // `.scaledToFill()` grew to.
            .frame(width: tileSide, height: tileSide)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: BackfillGrid.cornerRadius, style: .continuous)
                        .strokeBorder(Color.terracotta, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                // **No circle at all on a cloud-only tile.** It carries the unavailable treatment
                // and is not tappable, so an affordance offering to select it would be a control
                // that lies.
                if asset.isSelectable {
                    BackfillSelectionCircle(isSelected: isSelected).padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        // 0.98 over 0.12s, dropped entirely under Reduce Motion — the app's one tap feedback,
        // rather than the 0.9 shrink this grid used to do on its own.
        .buttonStyle(TapScaleButtonStyle())
        .disabled(!asset.isSelectable)
        .accessibilityLabel(Self.tileLabel(asset))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(asset.isSelectable ? "" : "Only in iCloud, so it can't be added.")
    }

    /// The rule, said once, at the moment it is met — not as a warning before anyone has done
    /// anything wrong.
    private func oneDayNote(_ day: Date) -> some View {
        HStack(spacing: 12) {
            Text("One day at a time — that's what keeps the date right.")
                .typeRole(.metadata)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Start here") {
                withAnimation(Motion.tap) { selection.startOver() }
            }
            .typeRole(.metadata)
            .fontWeight(.semibold)
            .foregroundStyle(Color.terracotta)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color.terracottaSoft,
            in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
        )
        .padding(.horizontal, Layout.screenMargin)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    // MARK: The action

    private var useButton: some View {
        Button {
            Task { await use() }
        } label: {
            Text(staging ? "Getting them ready…" : useLabel)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(staging)
        .padding(.horizontal, Layout.screenMargin)
        // 26 above, which is the height `docs/design-system.md` says a pinned action's fade needs
        // in order to actually fade. The gradient is `PinnedActionBackdrop`'s — the same clear-to-
        // canvas ground every other pinned action in the app sits on, rather than a second
        // hand-rolled fade that would drift from it.
        .padding(.top, 26)
        .padding(.bottom, 30)
        .background(PinnedActionBackdrop())
    }

    private var useLabel: String {
        selection.count == 1 ? "Use 1 photo" : "Use \(selection.count) photos"
    }

    private func tap(_ asset: BackfillAsset, in group: DayGroup) {
        withAnimation(Motion.tap) { selection.tap(asset, on: group.day) }
    }

    /// Stage the picked photos, then hand the composer a finished plan.
    ///
    /// Staged **here** rather than in the composer so the composer opens with the photos already on
    /// screen, and so a photo that cannot be read is reported while the parent is still looking at
    /// the grid it came from.
    private func use() async {
        guard let day = selection.day else { return }
        staging = true
        defer { staging = false }

        let picked = days
            .flatMap(\.assets)
            .filter { selection.assetIds.contains($0.id) }

        var drafts: [MediaDraft] = []
        var failed = 0
        for asset in picked {
            do {
                let data = try await source.imageData(for: asset.id)
                drafts.append(try MediaDraftBuilder.make(from: data, store: staged))
            } catch {
                // Not lost: the photo is still in the library, and the rest of the selection is
                // still a good entry. Counted rather than aborted.
                failed += 1
            }
        }

        guard !drafts.isEmpty else {
            notice = "Those couldn't be read, so nothing was added."
            return
        }
        if failed > 0 {
            notice = failed == 1
                ? "One of those couldn't be read, so it wasn't added."
                : "\(failed) of those couldn't be read, so they weren't added."
        }

        // The date rule's own answer, from the assets actually staged. Not recomputed anywhere
        // downstream — the composer renders this.
        let plan = BackfillEntryPlan(
            month: month,
            creationDates: picked.map(\.creationDate),
            calendar: calendar
        )
        onUse(plan, drafts, day)
        selection = BackfillSelection()
    }

    // MARK: Loading

    private func load() async {
        // **Only the first load shows a spinner.** A reload provoked by the loader's generation
        // moving — a widened selection, a grant that changed — would otherwise replace a populated
        // grid with a `ProgressView`, collapsing the scroll content and throwing the parent back to
        // the top of the month. Keeping the photographs on screen while the new ones are fetched is
        // both calmer and more honest: what is there is what the app could see a moment ago.
        if days.isEmpty { loading = true }
        // **Not an unconditional `loading = false`.** A cancelled load is always replaced by a
        // successor that has already set this true, so clearing it here writes over the live task
        // and the screen renders "Nothing in this month is on the phone to add." — the empty state —
        // over a month that has photos, for as long as the replacement takes. On a genuine teardown
        // nobody is left to read the flag.
        defer { if !Task.isCancelled { loading = false } }
        let assets = (try? await loader.assets(in: month)) ?? []
        // **A cancelled reload is not an empty month, and this guard is what keeps the two apart.**
        // `try?` swallows `CancellationError` into `[]`, and writing that through would blank the
        // grid and then hand `retain` an empty set — silently throwing away the photos the parent
        // had picked and the day they belong to. Re-keying this task on `loader.generation` is what
        // made cancellation an ordinary event here rather than a rare one, so the fix ships beside
        // the thing that caused it.
        if Task.isCancelled { return }
        // The family zone's calendar, the same one `use()` hands to `BackfillEntryPlan` — a day cut
        // in one zone and resolved in another is how a photo ends up an archive day away from the
        // header it was sitting under.
        let calendar = self.calendar
        // Assets with no creation date are dropped rather than pooled under an invented day. Their
        // date is exactly what the month fallback exists for, and giving them a day here would
        // launder a missing date into a real-looking one before the rule ever sees it.
        let grouped = Dictionary(grouping: assets.compactMap { asset -> (Date, BackfillAsset)? in
            guard let day = asset.day(calendar: calendar) else { return nil }
            return (day, asset)
        }) { $0.0 }

        days = grouped.keys.sorted().map { day in
            DayGroup(day: day, assets: (grouped[day] ?? []).map(\.1))
        }
        // This runs again now that a reload can be provoked by the library changing rather than
        // only by arriving on the screen. A selection pointing at photos that are no longer here
        // would put a count on the Use pill that staging cannot honour.
        //
        // **Scoped to the selection's own day, not to the month.** A photo whose date was edited
        // in Photos is still somewhere in this month, so a month-wide set keeps it selected while
        // the grid regroups it under a different header — and `use()` filters by id across every
        // day, so the entry would be built from two days' dates and filed under the earlier one.
        // The one-day rule is a date guarantee; this is where a reload could quietly break it.
        let onSelectedDay = days.first { $0.day == selection.day }?.assets.map(\.id) ?? []
        selection.retain(Set(onSelectedDay))
    }

    /// **The headers are read in the zone the days were cut in, not the device's.**
    ///
    /// A `DayGroup.day` is the start of a day in the child's `family_timezone`, and start-of-day
    /// there is the middle of the night — or the previous afternoon — somewhere else. Formatting
    /// that instant with the device's zone would print "Wed 30 September" over the group holding
    /// October's first morning, which is the off-by-a-day version of the bug the grouping itself
    /// was fixed to avoid.
    private static func headerStyle(in zone: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(timeZone: zone)
    }

    static func dayLabel(_ day: Date, in zone: TimeZone) -> String {
        day.formatted(headerStyle(in: zone).weekday(.abbreviated).day().month(.wide))
    }

    /// The two halves of the header's date, so the day can carry the weight and the month can sit
    /// back — `DayHeader`'s vocabulary. Split rather than styled through one string, because one
    /// `Text` cannot hold two ink steps.
    static func dayNumber(_ day: Date, in zone: TimeZone) -> String {
        day.formatted(headerStyle(in: zone).weekday(.abbreviated).day())
    }

    static func dayMonth(_ day: Date, in zone: TimeZone) -> String {
        day.formatted(headerStyle(in: zone).month(.wide))
    }

    static func tileLabel(_ asset: BackfillAsset) -> String {
        guard let date = asset.creationDate else { return "Photo" }
        return "Photo from \(date.formatted(.dateTime.hour().minute()))"
    }
}

// MARK: - Selection

/// The mark in the corner of every tile the parent can pick.
///
/// **It is there before the first tap, and that is the change.** A grid whose entire purpose is
/// selection, showing no affordance until after something is already selected, reads as broken —
/// the parent's first tap is a guess. So an unselected tile carries the empty ring and a selected
/// one fills it, which is the same object in two states rather than a badge that appears.
///
/// `docs/design-system.md`'s Backfill photo grid describes the older treatment — a 24pt circle at
/// the bottom trailing corner, drawn only when selected — and this supersedes it; the doc is
/// updated in the same change. A cloud-only tile gets no circle at all: see `tile`.
private struct BackfillSelectionCircle: View {
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed, not scaled. It sits inside a picture frame that does not grow — the same rule
    /// `docs/design-system.md` states for the mosaic's overflow numeral.
    private let diameter: CGFloat = 26

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.terracotta : Color.surface.opacity(0.7))
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.terracotta : Color.border,
                        lineWidth: Layout.borderWidth
                    )
                )
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.canvas)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(isSelected ? 1 : 0.4)
        }
        .frame(width: diameter, height: diameter)
        // Springs on the way in, and under Reduce Motion still fills over the same 0.35s without
        // the overshoot — the rule `CompletionCheck` follows. **No haptic**: haptics in this app
        // are reserved for completion, and picking a photo is not completing anything.
        .animation(Motion.completion(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityHidden(true)
    }
}
