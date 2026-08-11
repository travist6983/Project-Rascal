import SwiftUI

/// The share sheet's whole screen.
///
/// **The twelve-second screen with less room than usual.** What is on it: what is being saved,
/// when it happened, somewhere to type if there is anything to say, and Save. What is deliberately
/// not on it: prompt or assignment linkage, tags, people, sealing, and which child — every one of
/// those is a decision that belongs in the app, and a share sheet that asks five questions is
/// slower than opening the app was.
///
/// Freeform entries are first-class in this product, and this is a freeform capture path.
struct ShareComposer: View {
    @Bindable var model: ShareComposerModel
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var writing: Bool

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                switch model.phase {
                case .staging:
                    staging
                case .unusable(let message):
                    unusable(message)
                case .ready:
                    ready
                }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Cancel", action: onCancel)
                    .typeRole(.body)
                    .foregroundStyle(Color.inkMuted)
                Spacer()
            }
            Text("Add to the archive")
                .typeRole(.title)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, Layout.screenMargin)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    /// Copying a 4K video takes a moment, and a screen that says nothing during it reads as
    /// broken. No spinner over a blank sheet and no progress bar — there is no honest percentage
    /// to draw, because the copy is the kernel's and it does not report.
    private var staging: some View {
        VStack {
            Spacer()
            Text("Getting it ready…")
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Getting it ready")
    }

    /// Said plainly and without alarm, and with no Save button to press. The one thing this must
    /// never do is look like it saved.
    private func unusable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(message)
                .typeRole(.body)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Close", action: onCancel)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, Layout.screenMargin)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The screen proper

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SharePreviewRow(loaded: model.loaded)
                    dateBlock
                    noteBlock
                }
                .padding(.horizontal, Layout.screenMargin)
                .padding(.bottom, 20)
            }
            // The whole sheet scrolls rather than the note field alone, which is what keeps this
            // usable at the largest Dynamic Type sizes: at XXL the heading, the date, its
            // explanation and the field together are taller than a share sheet, and a fixed
            // layout would clip the Save button off the bottom.
            .scrollDismissesKeyboard(.interactively)

            saveBar
        }
    }

    /// **The detail that matters most on this screen.**
    ///
    /// A photo shared from Photos is usually not from today, so the date is shown rather than
    /// assumed — a 2023 photo filed under this week is a mistake nobody notices until the archive
    /// is already wrong, and the only cheap moment to catch it is before Save.
    ///
    /// It is shown and not edited, which is a deliberate narrowing. The capsule carries the
    /// composer's `DatePill` vocabulary — the same "Today"-or-the-full-date label, the same
    /// surface-on-cream capsule — but not its graphical picker: a month grid is most of a share
    /// sheet, and the entry it makes is editable in the app the moment the drain files it. What
    /// this screen owes the parent is the chance to *notice*, and that it does.
    private var dateBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("When it happened")

            Text(dateLabel)
                .typeRole(.metadata)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))

            Text(dateExplanation)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("When it happened, \(dateLabel). \(dateExplanation)")
    }

    private var dateLabel: String {
        ShareCopy.dateLabel(model.occurredAt)
    }

    private var dateExplanation: String {
        ShareCopy.dateExplanation(
            source: model.occurredAtSource,
            kinds: model.loaded.map(\.item.kind)
        )
    }

    private var noteBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Add a note — optional")
            TextField("Anything worth remembering", text: $model.note, axis: .vertical)
                .typeRole(.body)
                .foregroundStyle(Color.ink)
                .lineLimit(3...6)
                .padding(12)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                        .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
                )
                .focused($writing)
                .accessibilityLabel("Note, optional")
        }
    }

    /// One primary action. Terracotta, because saving is the primary action and terracotta is what
    /// this product paints those.
    private var saveBar: some View {
        Button("Save", action: onSave)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canSave)
            .opacity(model.canSave ? 1 : 0.5)
            .padding(.horizontal, Layout.screenMargin)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .background(Color.canvas)
            .accessibilityLabel("Save to the archive")
            .accessibilityHint(ShareCopy.saveHint(mediaCount: model.loaded.count))
    }
}
