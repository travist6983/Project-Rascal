import SwiftUI

/// How Entry Detail is opened, in one place, for every screen that opens it.
///
/// **It is presented full screen, not pushed.** It used to be a `navigationDestination` inside
/// the timeline's and Moments' `NavigationStack`s — and those stacks live inside `RootView`'s
/// `ZStack`, whose other child is the `FloatingTabBar`. The bar is a sibling of the whole tab,
/// not a member of any navigation stack, so nothing pushed on top of a tab can hide it: Entry
/// Detail rendered with the tab bar floating over the bottom of the photograph, plus the
/// `safeAreaPadding` that clears the bar reserved for it. `.toolbar(.hidden, for: .tabBar)`
/// cannot help either, because this app does not use a `TabView`.
///
/// A `fullScreenCover` is presented at the window level, above the root `ZStack` and everything
/// in it. That is what makes "no tab bar, no navigation bar" true rather than approximately true.
///
/// One modifier rather than the same twenty lines in two screens, so the timeline and Moments
/// cannot drift into opening the same screen two ways.
extension View {
    func entryDetail(
        _ request: Binding<EntryDetailRequest?>,
        childId: UUID,
        api: APIClient,
        openComposer: @escaping (ComposerRequest) -> Void,
        onDeleted: @escaping (UUID) -> Void
    ) -> some View {
        fullScreenCover(item: request) { opened in
            EntryDetailScreen(
                entryId: opened.id,
                childId: childId,
                api: api,
                openComposer: openComposer,
                onDeleted: { onDeleted(opened.id) }
            )
        }
    }
}

/// The entry being read. A wrapper rather than the bare `UUID` because `fullScreenCover(item:)`
/// needs `Identifiable`, and conforming `UUID` itself would be a conformance on a standard-library
/// type visible to the whole module.
struct EntryDetailRequest: Identifiable, Equatable {
    let id: UUID
}
