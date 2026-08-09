import SwiftData
import SwiftUI

/// This day, in the years before it.
///
/// Two shapes, one screen. When the archive has something from this month and day in a prior
/// year, that is what it shows, newest year first. When it does not, the server sends a handful
/// of real memories with `fallback: "random"` and the screen says so warmly — **never "you
/// haven't logged anything"**, which is the accusation this app does not make.
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
                VStack(alignment: .leading, spacing: 22) {
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

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Moments")
                .typeRole(.display)
                .foregroundStyle(Color.ink)
            Text(subtitle)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
        }
        .padding(.horizontal, Layout.screenMargin)
    }

    /// The date the server looked at, not one computed here — it is a calendar day in the
    /// child's timezone, and the client does not get to decide what day it is.
    private var subtitle: String {
        guard let model, model.hasLoaded else { return "Looking back" }
        if model.isFallback { return "Nothing from this day in another year" }
        return model.date.map { "On this day · \($0)" } ?? "On this day"
    }

    @ViewBuilder
    private var content: some View {
        if let model, model.hasLoaded {
            if model.sections.isEmpty {
                empty
            } else {
                if model.isFallback { fallbackNote }
                carousel(model.sections)
                sections(model.sections)
            }
        } else {
            ProgressView().tint(.terracotta)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    /// Warm and non-accusatory. Nothing was missed, and nothing here says it was.
    private var fallbackNote: some View {
        Text("Here's one from the archive instead.")
            .typeRole(.body)
            .foregroundStyle(Color.inkMuted)
            .padding(.horizontal, Layout.screenMargin)
    }

    private func carousel(_ sections: [MomentsModel.Section]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(sections) { section in
                    ThrowbackCard(
                        title: section.title,
                        subtitle: summary(section),
                        cover: section.cover
                    ) {
                        if let first = section.cards.first { path.append(first.id) }
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

    private func sections(_ sections: [MomentsModel.Section]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    SectionLabel(section.title)
                        .padding(.horizontal, Layout.screenMargin)
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
        .padding(.bottom, 20)
    }

    /// The archive has nothing at all yet — the fallback came back empty too. An invitation
    /// rather than a report.
    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.terracotta)
            Text("The first one becomes a memory")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
            Text("Anything you save today shows up here a year from now.")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button("Save something") {
                openComposer(ComposerRequest(childId: childId, assignment: nil, mode: .text))
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Gradients.wash, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
        .padding(.horizontal, Layout.screenMargin)
        .padding(.top, 40)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.inkMuted)
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
