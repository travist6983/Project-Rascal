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
    }

    private(set) var sections: [Section] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// True when the server had nothing for this day and sent memories instead.
    private(set) var isFallback = false
    /// The day the server looked at, `YYYY-MM-DD`, in the child's timezone.
    private(set) var date: String?
    var notice: String?

    private let childId: UUID
    private let api: APIClient
    private let context: ModelContext

    init(childId: UUID, api: APIClient, context: ModelContext) {
        self.childId = childId
        self.api = api
        self.context = context
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
            let response = try await api.moments(childId: childId)
            // Cached like any other entries, so a memory opened here and the same row in the
            // timeline are one row — and so this screen still has something to show offline.
            EntryCache.upsert(response.allEntries, into: context)

            date = response.date
            isFallback = response.isFallback
            sections = response.isFallback
                ? [build(title: "From the archive", id: "random", entries: response.entries)].compactMap { $0 }
                : response.groups.compactMap { build(title: $0.title, id: "y\($0.yearsAgo)", entries: $0.entries) }
            hasLoaded = true
            notice = nil
        } catch let error as APIError {
            notice = error.userMessage
            hasLoaded = true
        } catch {
            notice = error.localizedDescription
            hasLoaded = true
        }
    }

    /// Cards are built from the cached rows rather than from the response, so a memory renders
    /// with whatever media this phone already has — including a thumbnail the composer wrote
    /// months ago and never had to fetch again.
    private func build(title: String, id: String, entries: [EntryResponse]) -> Section? {
        let cards = entries.compactMap { response -> EntryCardModel? in
            guard let entry = EntryCache.entry(id: response.id, in: context), entry.deletedAt == nil
            else { return nil }
            return EntryCardModel(entry: entry, media: EntryCache.media(ofEntry: entry.id, in: context))
        }
        guard !cards.isEmpty else { return nil }
        return Section(
            id: id,
            title: title,
            cards: cards,
            // Video is a fine cover — the poster frame is local when the video was taken here.
            cover: cards.compactMap { $0.thumbnails.first }.first
        )
    }
}
