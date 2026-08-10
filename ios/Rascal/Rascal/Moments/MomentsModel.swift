import Foundation
import SwiftData

/// On This Day.
///
/// `GET /children/{id}/moments` answers in one of two shapes and the client renders both: entries
/// from this month and day in prior years, grouped by years-ago — or, when there are none, a
/// handful of real memories with `fallback: "random"` set. **The screen is never a void**, which
/// is the whole reason the fallback exists server-side.
///
/// The date is the server's. It is computed in the child's `family_timezone`, and a client that
/// decided what day it was would show the wrong memories to anyone who travels.
@MainActor
@Observable
final class MomentsModel {

    /// One band of the screen: a years-ago group, or the warm redirect.
    struct Section: Identifiable {
        let id: String
        /// "1 year ago", or the fallback's own heading.
        let title: String
        let cards: [EntryCardModel]
        /// The first picture in the section, for the throwback card behind its gradient.
        let cover: EntryCardModel.Thumbnail?
        /// How many years back this band reaches. Nil for the warm redirect, which reaches
        /// nowhere in particular — that is the whole point of it.
        let yearsAgo: Int?
        /// The calendar day these memories happened on, when they share one. **Nil for the
        /// fallback**, whose five come from five different days: printing one of their dates
        /// over all five would date four memories wrongly, permanently, in an archive.
        let occurredOn: Date?
        /// How old he was, when the whole band can answer that with one number. Nil for the
        /// fallback for the same reason as `occurredOn`.
        let ageMonths: Int?

        var isFallback: Bool { yearsAgo == nil }
    }

    private(set) var sections: [Section] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// True when the server had nothing for this day and sent memories instead.
    private(set) var isFallback = false
    /// The last load did not get an answer.
    ///
    /// **Distinct from having no sections, and the distinction is the whole point.** "The archive
    /// is empty" and "I could not reach the server" both leave `sections` empty, and the screen
    /// must never answer the second with the first — telling a parent holding 755 entries that
    /// there is nothing to look back on because a train went into a tunnel is exactly the
    /// accusation this app does not make.
    private(set) var failed = false
    /// The day the server looked at, `YYYY-MM-DD`, in the child's timezone.
    private(set) var date: String?
    var notice: String?

    private let childId: UUID
    private let api: APIClient
    private let context: ModelContext
    /// A specific day to *ask about*, `YYYY-MM-DD`, or nil for the server's own idea of today.
    ///
    /// Nil is the shipping path and the right default: the day is computed in the child's
    /// `family_timezone`, and a client that decided what day it was would show the wrong
    /// memories to anyone who travels. This exists so a caller can name a day — which is a
    /// different thing from deciding which day today is.
    ///
    /// Distinct from `date`, which is the day the server *answered* for and is the only one the
    /// screen ever prints.
    private let requestedDate: String?

    init(childId: UUID, api: APIClient, context: ModelContext, date: String? = nil) {
        self.childId = childId
        self.api = api
        self.context = context
        self.requestedDate = date
    }

    func start() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    func refresh(thumbnails: ThumbnailStore? = nil) async {
        thumbnails?.retryFailures()
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.moments(childId: childId, date: requestedDate)
            // Cached like any other entries, so a memory opened here and the same row in the
            // timeline are one row — and so this screen still has something to show offline.
            EntryCache.upsert(response.allEntries, into: context)

            date = response.date
            isFallback = response.isFallback
            sections = response.isFallback
                ? [build(title: "From the archive", id: "random", yearsAgo: nil, entries: response.entries)]
                    .compactMap { $0 }
                : response.groups.compactMap {
                    build(title: $0.title, id: "y\($0.yearsAgo)", yearsAgo: $0.yearsAgo, entries: $0.entries)
                }
            hasLoaded = true
            notice = nil
            failed = false
        } catch let error as APIError {
            notice = error.userMessage
            hasLoaded = true
            failed = true
        } catch {
            notice = error.localizedDescription
            hasLoaded = true
            failed = true
        }
    }

    /// Cards are built from the cached rows rather than from the response, so a memory renders
    /// with whatever media this phone already has — including a thumbnail the composer wrote
    /// months ago and never had to fetch again.
    private func build(
        title: String, id: String, yearsAgo: Int?, entries: [EntryResponse]
    ) -> Section? {
        let cards = entries
            .compactMap { response -> EntryCardModel? in
                guard let entry = EntryCache.entry(id: response.id, in: context), entry.deletedAt == nil
                else { return nil }
                return EntryCardModel(entry: entry, media: EntryCache.media(ofEntry: entry.id, in: context))
            }
            // **`occurredAt`, never `createdAt`.** A photo backfilled from the camera roll last
            // night belongs to the year it happened, not to the night it was imported — and the
            // fallback arrives in `random()` order, so this is the only thing giving those five
            // an order at all.
            .sorted { $0.occurredAt > $1.occurredAt }
        guard !cards.isEmpty else { return nil }
        return Section(
            id: id,
            title: title,
            cards: cards,
            // Video is a fine cover — the poster frame is local when the video was taken here.
            cover: cards.compactMap { $0.thumbnails.first }.first,
            yearsAgo: yearsAgo,
            // One day for a years-ago band, because every entry in it fell on the same month and
            // day of the same year. The fallback gets neither, and the header prints neither.
            occurredOn: yearsAgo == nil ? nil : cards.first?.occurredAt,
            ageMonths: yearsAgo == nil ? nil : cards.first?.ageMonths
        )
    }
}
