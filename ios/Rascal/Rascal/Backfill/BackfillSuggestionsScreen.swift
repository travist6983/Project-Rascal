import SwiftUI

/// "Look back" — this month in the years before it, and then every month the child has been alive.
///
/// Two sections doing different jobs. **Suggested** is a throwback: the same calendar month walking
/// back through up to five prior years, each one dismissible. Five is a ceiling and not a target —
/// a candidate that is empty, dismissed, or older than the child shortens the list rather than
/// being replaced, because the section's premise is "this month, earlier" and a substituted June
/// would read as August. **Every month** is a map: everything the camera roll holds from the
/// child's first month onward, including what has already been written about and what has been set
/// aside, because a browse list that hides things is one a parent stops trusting.
///
/// **Both lists are scoped by the caller**, against the child's `family_timezone` and birthdate.
/// This view renders what it is handed and computes no months of its own — a screen that decided
/// what month it was would be the `daysUntilExpiry` defect wearing a different hat.
struct BackfillSuggestionsScreen: View {
    /// This month, in the years before it — at most five, floored at the month the child was born
    /// in, and **already scoped by the caller**. See `BackfillPlan.suggested`.
    let suggested: [BackfillMonthSummary]
    /// Every month worth browsing, floored at `birthMonth` and stopping before this one. Also
    /// scoped by the caller — see `BackfillPlan.browsable`.
    let months: [BackfillMonthSummary]
    let childBirthdate: Date?
    /// Selected-photos access. **Every count on this screen is a count of the selection**, so the
    /// screen has to say so — a month total computed over a fraction of the library is wrong
    /// while looking entirely normal, which is the same failure shape as a photo filed under the
    /// wrong day.
    var isLimited: Bool = false
    /// Widen the selection. Nil where there is nothing to widen.
    var onWidenSelection: (() -> Void)?
    let onOpen: (BackfillMonth) -> Void
    let onDismissMonth: (BackfillMonth) -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            // **`LazyVStack`, and this is half the crash.** A plain `VStack` inside a `ScrollView`
            // mounts every child on the first render — it has no viewport to be lazy about. With
            // one card per month back to 2012 that was 175 `BackfillMonthCard`s built at once,
            // each firing a `.task` that read a whole month of the library and then requested four
            // thumbnails: **175 month reads, 700 thumbnail requests and 643MB resident against a
            // 236MB baseline**, none of it on screen, all of it before the first frame. Measured on
            // a seeded library of 2,450 photos across 175 months; a real archive is several times
            // that, and every figure here scales with it.
            //
            // The other half is the five-card ceiling in `BackfillPlan.suggested`. **Neither fix
            // is sufficient alone** — laziness without the ceiling still costs the full 175 unless
            // the `ForEach` below is a direct child of this stack, and the ceiling without
            // laziness leaves `EVERY MONTH` as long as the child is old.
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Look back")
                    .typeRole(.display)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 8)
                Text(intro)
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                if isLimited {
                    LimitedLibraryNotice(onWiden: onWidenSelection)
                        .padding(.top, 18)
                }

                // **Absent, not empty.** Every candidate dismissed or empty means no header and no
                // placeholder card — `docs/design-system.md`: no zone renders an empty frame, and a
                // count of zero is an absent row. `EVERY MONTH` stands alone and the screen still
                // reads as a screen.
                if !suggested.isEmpty {
                    SectionLabel("Suggested")
                        .padding(.top, 24)
                        .padding(.bottom, 10)
                    // **The `ForEach` is a direct child of the `LazyVStack`, and that is not a
                    // style choice.** It was wrapped in a plain `VStack(spacing:)` for the card
                    // gap, and a lazy stack sees a nested stack as *one* child — so it built the
                    // whole thing eagerly and the laziness bought nothing. Measured: with the
                    // wrapper in place a 175-month library still issued 175 month reads and 700
                    // thumbnail requests, identical to the plain `VStack` it replaced. The gap is
                    // per-card padding instead, which keeps each card its own lazy child.
                    ForEach(suggested) { summary in
                        BackfillMonthCard(
                            month: summary.month,
                            assetCount: summary.assetCount,
                            childBirthdate: childBirthdate,
                            onOpen: { onOpen(summary.month) },
                            onDismiss: { onDismissMonth(summary.month) }
                        )
                        // Between cards, not after the last one. A trailing gap here would stack on
                        // "Every month"'s own 34 and open the two sections further apart than the
                        // `VStack(spacing:)` this replaced ever did.
                        .padding(.bottom, summary.id == suggested.last?.id ? 0 : Layout.cardSpacing)
                    }
                }

                if !months.isEmpty {
                    SectionLabel("Every month")
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    everyMonth
                }
            }
            .padding(.horizontal, Layout.screenMargin)
            .padding(.bottom, 40)
        }
        .background(Color.canvas)
        .navigationTitle("Camera roll")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onClose).foregroundStyle(Color.inkMuted)
            }
        }
    }

    /// **The opening sentence is a claim about the library, so it changes when the library is a
    /// selection.** "There's a lot here you haven't written about yet" is only true of everything
    /// the app can see, and under `.limited` that is whatever was shared.
    private var intro: String {
        isLimited
            ? "These are the photos you've shared with Dogear. Pick a month and start anywhere."
            : "There's a lot here you haven't written about yet. Pick a month and start anywhere."
    }

    /// Grouped by year, newest first. The grouping is done here rather than in the model because
    /// it is presentation — `monthIndex` returns a flat, sorted list and stays that way.
    private var everyMonth: some View {
        ForEach(years, id: \.year) { group in
            VStack(alignment: .leading, spacing: 8) {
                Text(String(group.year))
                    .typeRole(.cardTitle)
                    .foregroundStyle(Color.ink)
                VStack(spacing: 0) {
                    ForEach(Array(group.months.enumerated()), id: \.element.id) { index, summary in
                        Button { onOpen(summary.month) } label: {
                            monthRow(summary)
                        }
                        .buttonStyle(TapScaleButtonStyle())
                        if index < group.months.count - 1 {
                            Divider().overlay(Color.border).padding(.leading, Layout.cardPadding)
                        }
                    }
                }
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                )
            }
            .padding(.bottom, 18)
        }
    }

    private func monthRow(_ summary: BackfillMonthSummary) -> some View {
        HStack(spacing: 10) {
            Text(summary.month.monthName())
                .typeRole(.cardTitle)
                .fontWeight(.regular)
                .foregroundStyle(Color.ink)
            Spacer(minLength: 4)
            Text(photoCount(summary.assetCount))
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
            if summary.isLogged {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(entryCount(summary.entryCount))
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(Color.sageInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.sage, in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkFaint)
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        // A month already written about is quieter, not hidden — it is still a door.
        .opacity(summary.isLogged ? 0.62 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowLabel(summary))
        .accessibilityAddTraits(.isButton)
    }

    private func rowLabel(_ summary: BackfillMonthSummary) -> String {
        var parts = [summary.month.monthName(), photoCount(summary.assetCount)]
        if summary.isLogged { parts.append(entryCount(summary.entryCount)) }
        return parts.joined(separator: ", ")
    }

    private func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }

    private func entryCount(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    private var years: [(year: Int, months: [BackfillMonthSummary])] {
        let grouped = Dictionary(grouping: months) { $0.month.year }
        return grouped.keys.sorted(by: >).map { year in
            (year: year, months: (grouped[year] ?? []).sorted { $0.month > $1.month })
        }
    }
}

// MARK: - A suggested month

/// One month worth writing about: what is in it, a glance at it, and a way to say not this one.
///
/// Takes a month and a count rather than a `BackfillCluster`. The card never read the cluster's
/// third field — `cloudOnlyCount` reaches no pixel on this screen — and `SUGGESTED` is now built
/// from the month index rather than from the offer, so asking for a cluster would mean minting one
/// with a fabricated count to satisfy a parameter nothing draws.
struct BackfillMonthCard: View {
    let month: BackfillMonth
    let assetCount: Int
    let childBirthdate: Date?
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 4) {
                        monthTitle
                        Text(assetCount == 1 ? "1 photo" : "\(assetCount) photos")
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TapScaleButtonStyle())

                // A menu rather than a swipe: this sits inside a vertical scroll view, and a
                // swipe-to-dismiss on a card in a scrolling list is a gesture people trigger by
                // accident and cannot find on purpose.
                Menu {
                    Button("Not this one", action: onDismiss)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.inkMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More options for \(month.label())")
            }

            Button(action: onOpen) {
                BackfillMonthThumbnailStrip(month: month, total: assetCount)
                    .padding(.top, 14)
            }
            .buttonStyle(TapScaleButtonStyle())

            if let age = ageLine {
                Text(age)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, 14)
            }
        }
        .cardSurface()
        .accessibilityElement(children: .contain)
    }

    /// **One `Text`, not two in an `HStack`.** Side by side, the month is a separate layout box
    /// from the year and gets squeezed until it breaks *inside the word* — at the largest Dynamic
    /// Type sizes "October 2025" rendered as "Octobe / r" beside an untouched "2025". Concatenated,
    /// it wraps as the phrase it is. `String(year)` rather than interpolating the `Int`, which a
    /// locale would render as "2,025".
    private var monthTitle: some View {
        (
            Text(month.monthName()).foregroundStyle(Color.ink)
                + Text(" " + String(month.year)).foregroundStyle(Color.inkFaint)
        )
        .typeRole(.detailTitle)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Neutrally worded. The mockup says "He was…"; new client copy does not assume a gender —
    /// see `CLAUDE.md`. `DraftAge` because a month with no entries has no server age to render.
    private var ageLine: String? {
        guard let childBirthdate else { return nil }
        let at = month.fallbackDate()
        guard childBirthdate <= at else { return nil }
        return DraftAge.spoken(from: childBirthdate, to: at)
    }
}

/// Four tiles from the month, the last carrying the remainder.
///
/// Fetched lazily, one month at a time, when the card appears. `+58` is printed **on** the fourth
/// tile rather than given a tile of its own, the same rule `EntryCard`'s mosaic follows — so a
/// month with sixty photos and one with six produce the same card height.
struct BackfillMonthThumbnailStrip: View {
    let month: BackfillMonth
    let total: Int

    @Environment(BackfillThumbnailLoader.self) private var loader
    @State private var assets: [BackfillAsset] = []

    private let shown = 4

    var body: some View {
        HStack(spacing: 6) {
            if assets.isEmpty {
                ForEach(0..<shown, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                        .fill(Color.chipPlain)
                        .frame(height: 74)
                }
            } else {
                ForEach(Array(assets.prefix(shown).enumerated()), id: \.element.id) { index, asset in
                    BackfillThumbnail(asset: asset)
                        .frame(height: 74)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            if index == shown - 1, remainder > 0 {
                                ZStack {
                                    Color.ink.opacity(0.42)
                                    Text("+\(remainder)")
                                        .typeRole(.metadata)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.canvas)
                                }
                                .clipShape(
                                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                                )
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .task(id: month.key) {
            assets = (try? await loader.assets(in: month)) ?? []
        }
    }

    private var remainder: Int { max(0, total - shown) }
}

// MARK: - Limited access

/// What the browse surface says when it can only see a selection.
///
/// **Not an error, and not a scolding.** The parent made a deliberate, reasonable choice. What it
/// does is stop every count on the screen from reading as a complete one, because a month total
/// computed over a fraction of the library is wrong in a way nothing on screen would reveal.
///
/// Two ways out, and neither is a re-prompt: widening the selection is a picker iOS will show any
/// number of times, and Settings is the only place full access can be granted. `docs/decisions.md`
/// records that this app builds no retry funnel, and neither of these is one — iOS's own
/// permission prompt is never fired twice.
struct LimitedLibraryNotice: View {
    var onWiden: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You've shared some of your photos")
                .typeRole(.cardTitle)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Counts here cover the photos you've shared, not your whole library.")
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                if let onWiden {
                    Button("Share more photos", action: onWiden)
                        .typeRole(.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.terracotta)
                }
                SettingsLinkText()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }
}

/// The quiet route to the app's own Settings page, as inline text rather than a bordered button.
struct SettingsLinkText: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings") {
            #if canImport(UIKit)
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            #endif
        }
        .typeRole(.metadata)
        .fontWeight(.semibold)
        .foregroundStyle(Color.inkMuted)
    }
}
