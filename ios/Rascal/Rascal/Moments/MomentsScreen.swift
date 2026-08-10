import SwiftData
import SwiftUI

/// This day, in the years before it.
///
/// Two shapes, one screen. When the archive has something from this month and day in a prior
/// year, that is what it shows, nearest year first. When it does not, the server sends a handful
/// of real memories with `fallback: "random"` and the screen says so warmly — **never "you
/// haven't logged anything"**, which is the accusation this app does not make.
///
/// **The fallback is the ordinary case, not the edge.** The archive is days old; "1 year ago"
/// will be empty on nearly every date for a year, and on many dates for years after that. So the
/// redirect wears the same carousel, the same section header and the same cards as a hit — only
/// the eyebrow and one italic line differ. A miss that looked like a miss would be a screen this
/// app showed most of the time, and it would read as a fault every one of them.
struct MomentsScreen: View {
    let childId: UUID
    let api: APIClient
    let openComposer: (ComposerRequest) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.thumbnails) private var thumbnails
    @State private var model: MomentsModel?
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let notice = model?.notice { noticeBanner(notice) }
                    content
                }
                .padding(.vertical, 8)
            }
            .background(Color.canvas)
            .refreshable { await model?.refresh(thumbnails: thumbnails) }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                EntryDetailScreen(
                    entryId: id,
                    childId: childId,
                    api: api,
                    openComposer: openComposer,
                    onDeleted: {
                        path.removeAll { $0 == id }
                        // The section this memory was in may now be empty. Rebuilt rather than
                        // left showing a card for a row that is gone.
                        Task { await model?.load() }
                    }
                )
            }
        }
        .task {
            if model == nil {
                model = MomentsModel(childId: childId, api: api, context: context)
            }
            await model?.start()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Moments")
                .typeRole(.display)
                .foregroundStyle(Color.ink)
                // The screen's own heading, so the rotor lands here before the year sections.
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Layout.screenMargin)
    }

    /// The date the server looked at, not one computed here — it is a calendar day in the child's
    /// timezone, and the client does not get to decide what day it is.
    ///
    /// **It says the same thing on a miss as on a hit.** The redirect is announced once, in the
    /// section's own note, rather than in the screen's title where it would become the headline
    /// of a screen the parent sees most days.
    private var subtitle: String {
        guard let model, model.hasLoaded else { return "Looking back" }
        guard let date = model.date, let day = CalendarDay.weekdayDayMonth(date) else {
            return "On this day"
        }
        return "On this day · \(day)"
    }

    @ViewBuilder
    private var content: some View {
        if let model, model.hasLoaded {
            if model.sections.isEmpty {
                empty
            } else {
                carousel(model.sections)
                sections(model.sections)
                if let footer { footerLine(footer) }
            }
        } else {
            ProgressView().tint(.terracotta)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    // MARK: Carousel

    /// One card per throwback — and a throwback is a **year** on a hit and a **memory** on the
    /// redirect.
    ///
    /// Three sections give three cards headed "1 year ago", "3 years ago", "6 years ago", each
    /// standing for the band below it. The redirect has only ever one section, so taking one card
    /// per section would leave a rail holding a single card beside a screen of five memories —
    /// and that is the state this build is in most days. It takes one per memory instead.
    private struct Throwback: Identifiable {
        let id: UUID
        let eyebrow: String
        let line: String
        let cover: EntryCardModel.Thumbnail?
        let badge: (label: String, tint: Color)?
    }

    private func throwbacks(_ sections: [MomentsModel.Section]) -> [Throwback] {
        sections.flatMap { section -> [Throwback] in
            guard section.isFallback else {
                guard let lead = section.cards.first else { return [] }
                return [Throwback(
                    id: lead.id,
                    eyebrow: section.title,
                    line: summary(section),
                    cover: section.cover,
                    badge: badge(for: lead, hasCover: section.cover != nil)
                )]
            }
            return section.cards.map { card in
                Throwback(
                    id: card.id,
                    eyebrow: section.title,
                    line: card.title ?? card.preview ?? "1 memory",
                    cover: card.thumbnails.first,
                    badge: badge(for: card, hasCover: card.thumbnails.first != nil)
                )
            }
        }
    }

    private func carousel(_ sections: [MomentsModel.Section]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(throwbacks(sections)) { throwback in
                    ThrowbackCard(
                        title: throwback.eyebrow,
                        subtitle: throwback.line,
                        cover: throwback.cover,
                        badge: throwback.badge?.label,
                        badgeTint: throwback.badge?.tint ?? .terracotta
                    ) {
                        path.append(throwback.id)
                    }
                }
            }
            .padding(.horizontal, Layout.screenMargin)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The entry's own words where there are any, and a plain count where there are not. A
    /// did-it memory has nothing to quote and should not be given a made-up caption.
    private func summary(_ section: MomentsModel.Section) -> String {
        if let first = section.cards.first, let line = first.title ?? first.preview {
            return line
        }
        let count = section.cards.count
        return count == 1 ? "1 memory" : "\(count) memories"
    }

    /// What the section leads with, when the cover cannot say it.
    ///
    /// Shown whenever the section has no picture — a wash with two lines on it and no other
    /// signal reads as a photo that failed — and over a picture only for video, where a still
    /// frame does not tell you the thing moves.
    private func badge(for lead: EntryCardModel, hasCover: Bool) -> (label: String, tint: Color)? {
        // A sealed letter is not its `entry_type`, and "Written" would describe the wrong thing
        // about the one card on this screen whose contents are deliberately not shown.
        if lead.isSealed { return ("Letter", .terracotta) }
        guard !hasCover || lead.type == .video else { return nil }
        guard let label = lead.typeLabel else { return nil }
        let tint: Color = switch lead.tint {
        case .terracotta: .terracotta
        case .periwinkle: .periwinkle
        case .sage: .sageInk
        }
        return (label, tint)
    }

    // MARK: Sections

    private func sections(_ sections: [MomentsModel.Section]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(section)
                    if let note = note(for: section) {
                        Text(note)
                            .typeRole(.quote)
                            .italic()
                            .foregroundStyle(Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Layout.screenMargin)
                    }
                    VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        ForEach(section.cards) { card in
                            Button { path.append(card.id) } label: {
                                EntryCard(model: card)
                            }
                            .buttonStyle(TapScaleButtonStyle())
                            .padding(.horizontal, Layout.screenMargin)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    /// Years-ago, the day it happened, and how old he was — stated once for the group rather than
    /// repeated on every card, which is where the age went in v3.
    private func sectionHeader(_ section: MomentsModel.Section) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.title)
                .typeRole(.dayNumber)
                .foregroundStyle(Color.inkMuted)
                .accessibilityAddTraits(.isHeader)
            if let occurredOn = section.occurredOn {
                Text(DayHeaderText.compact(occurredOn))
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 0)
            // **No age chip on the fallback.** Its five memories come from five different days
            // and five different ages; one number over all of them would be wrong for four.
            if let months = section.ageMonths {
                Chip(
                    text: AgeText.chip(months),
                    foreground: .periwinkle,
                    background: .periwinkleSoft,
                    emphasis: true
                )
                .accessibilityLabel(AgeText.spoken(months))
            }
        }
        .padding(.horizontal, Layout.screenMargin)
    }

    /// The one line that distinguishes a miss from a hit — and it names the day rather than the
    /// parent. Nothing here reports what anyone failed to do.
    private func note(for section: MomentsModel.Section) -> String? {
        guard section.isFallback else { return nil }
        guard let date = model?.date, let day = CalendarDay.dayMonth(date) else {
            return "Here's one from the archive instead."
        }
        return "Nothing from \(day) yet. Here's one from the archive instead."
    }

    // MARK: Footer

    /// The closing line under the archive.
    ///
    /// Only what the response can support. The design also draws a line naming how many memories
    /// *tomorrow* holds; `GET /children/{id}/moments` answers for one day, so the client cannot
    /// know that without a second request for a day nobody asked about, and inventing it is not
    /// available. See the pull request.
    private var footer: String? {
        guard let model, model.hasLoaded, !model.sections.isEmpty, !model.isFallback else {
            return nil
        }
        guard let oldest = model.sections.compactMap(\.yearsAgo).max() else { return nil }
        if oldest == 1 { return "One year down. This gets fuller." }
        guard let date = model.date, let day = CalendarDay.dayMonth(date) else { return nil }
        let spelled = NumberFormatter.spelled(oldest)
        return "\(spelled) years of \(day). Nothing else today."
    }

    private func footerLine(_ text: String) -> some View {
        Text(text)
            .typeRole(.metadata)
            .foregroundStyle(Color.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
    }

    // MARK: Empty

    /// The archive has nothing at all yet — the fallback came back empty too. An invitation
    /// rather than a report, and one button that opens the composer rather than explaining
    /// the feature.
    private var empty: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Gradients.wash)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.terracotta)
            }
            .frame(width: 66, height: 66)
            .accessibilityHidden(true)

            Text("The first one becomes a memory")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            Text("Nothing to look back on yet. A year from now this screen is where today ends up.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 290)
                .padding(.top, 9)

            Button("Capture something") {
                openComposer(ComposerRequest(childId: childId, assignment: nil, mode: .text))
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(maxWidth: 240)
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.top, 58)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.inkMuted)
                .accessibilityHidden(true)
            Text(text).typeRole(.metadata).foregroundStyle(Color.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
        .padding(.horizontal, Layout.screenMargin)
    }
}

extension NumberFormatter {
    /// "Six", for the closing line. A numeral there reads as a statistic, and this screen is not
    /// keeping score of anything.
    static func spelled(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        guard let words = formatter.string(from: NSNumber(value: value)) else { return "\(value)" }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
