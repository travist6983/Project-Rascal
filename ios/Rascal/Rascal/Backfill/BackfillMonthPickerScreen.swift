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
    let source: any BackfillAssetSource
    let childBirthdate: Date?
    /// Days written during this visit, checked off without waiting for a rescan.
    let savedDays: Set<Date>
    /// Selected-photos access. **The month total in the subtitle is a count of what the app can
    /// see**, and under `.limited` that is the shared selection rather than the month — so it says
    /// which. The grid below is self-describing (the photos are right there); a total above it is
    /// not, and reads as a fact about the month.
    var isLimited: Bool = false
    let onUse: (BackfillEntryPlan, [MediaDraft], Date) -> Void

    @Environment(BackfillThumbnailLoader.self) private var loader

    @State private var days: [DayGroup] = []
    @State private var loading = true
    /// The one-day rule lives in `BackfillSelection`, not in this view — see that type.
    @State private var selection = BackfillSelection()
    @State private var staging = false
    @State private var notice: String?

    private let staged = StagingStore()

    struct DayGroup: Identifiable, Equatable {
        let day: Date
        let assets: [BackfillAsset]
        var id: Date { day }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
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
            .padding(.bottom, selection.isEmpty ? 40 : 110)
        }
        .background(Color.canvas)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { useButton }
        }
        .task(id: month.key) { await load() }
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

    private func dayHeader(_ group: DayGroup) -> some View {
        HStack(spacing: 10) {
            Text(Self.dayLabel(group.day))
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
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
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func dayGrid(_ group: DayGroup) -> some View {
        if selection.blockedDay == group.day { oneDayNote(group.day) }

        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
            spacing: 3
        ) {
            ForEach(group.assets) { asset in
                tile(asset, in: group)
            }
        }
        .padding(.horizontal, Layout.screenMargin)
        .padding(.bottom, 14)
    }

    private func tile(_ asset: BackfillAsset, in group: DayGroup) -> some View {
        let isSelected = selection.contains(asset)
        return Button {
            tap(asset, in: group)
        } label: {
            BackfillThumbnail(asset: asset, cornerRadius: isSelected ? 10 : 2)
                .aspectRatio(1, contentMode: .fill)
                .scaleEffect(isSelected ? 0.9 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.surface)
                            .frame(width: 24, height: 24)
                            .background(Color.terracotta, in: Circle())
                            .padding(6)
                    }
                }
                .animation(Motion.tap, value: isSelected)
        }
        .buttonStyle(.plain)
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
        .padding(.bottom, 30)
        .background(
            LinearGradient(
                colors: [Color.canvas.opacity(0), Color.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
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
            creationDates: picked.map(\.creationDate)
        )
        onUse(plan, drafts, day)
        selection = BackfillSelection()
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        let assets = (try? await loader.assets(in: month)) ?? []
        let calendar = Calendar.current
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
    }

    static func dayLabel(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
    }

    static func tileLabel(_ asset: BackfillAsset) -> String {
        guard let date = asset.creationDate else { return "Photo" }
        return "Photo from \(date.formatted(.dateTime.hour().minute()))"
    }
}
