import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Changing and removing the child's photo, after onboarding.
///
/// Onboarding could always set one and Settings could always show one; between the two there was
/// no way to replace a photo or take it back. This is that surface, and it is deliberately small:
/// choose another, take another, remove — the same three things `AvatarStep` offers, in the
/// vocabulary Settings uses.
///
/// **It is not reached from the hero disc.** `docs/design-system.md` settles `ChildHeroCard` as one
/// button into one sheet with one combined accessibility element; a second tap target inside it
/// would be unreachable under VoiceOver and Switch Control and would make the card's existing hint
/// false. The door is a `Photo` row in the archive card instead.
///
/// **Nothing here has an upload state, including the removal.** `docs/design-system.md`: "The
/// avatar has no upload state, and that is the design." The crop is written to disk and on screen
/// before anything touches the network, and a removal deletes the file on the tap; the server is
/// told on the ordinary foreground sweep. `SettingsActionRow.isBusy` is left false everywhere on
/// this sheet and nothing sets it.
struct ChildPhotoSheet: View {
    /// For the removal dialog's message, which names the child rather than using a pronoun.
    let childName: String
    /// A 512px square JPEG, already through `AvatarCrop`. The caller enqueues it.
    let onChoose: (Data) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// What this sheet is showing. Seeded from the caller's bytes **in `init`, and never again.**
    ///
    /// It was seeded in `.onAppear` under a `shown == nil` guard, which is wrong in a way that only
    /// shows up after a removal: `shown` is legitimately nil then, so any second `onAppear` — and
    /// the camera sheet dismissing over this one can produce one — re-seeds from the caller's
    /// stale bytes and puts the removed photo back on screen with its Remove row. Seeding here runs
    /// exactly once per presentation, because `.sheet(item:)` builds this view fresh each time.
    ///
    /// The incoming bytes are deliberately *not* kept as a property: with nothing stale to read
    /// back, that bug is unavailable rather than merely fixed.
    @State private var shown: Data?

    @State private var pick: PhotosPickerItem?
    @State private var showingPicker = false
    @State private var showingCamera = false
    @State private var confirmingRemove = false
    @State private var processingFailed = false

    init(
        childName: String,
        avatar: Data?,
        onChoose: @escaping (Data) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.childName = childName
        self.onChoose = onChoose
        self.onRemove = onRemove
        _shown = State(initialValue: avatar)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AvatarDisc(data: shown)
                        .frame(maxWidth: .infinity)

                    Text(ChildPhotoCopy.subtitle)
                        .typeRole(.metadata)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    SettingsCard {
                        SettingsActionRow(
                            label: shown == nil ? "Choose a photo" : "Choose another"
                        ) {
                            showingPicker = true
                        }

                        #if canImport(UIKit)
                        // Hidden where there is no camera — the same gate `AvatarStep` uses, and
                        // for its reason: a button that opens nothing is worse than an absent one,
                        // and the simulator has no camera at all.
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            SettingsDivider()
                            SettingsActionRow(label: "Take a photo") { showingCamera = true }
                        }
                        #endif
                    }

                    // **Its own card, with whitespace above it rather than a divider.** A divider
                    // between two rows says "these belong together"; a gap says "these do not".
                    // Choose and Take are two ways to set a photo — Remove is not a third. The
                    // shape is `SettingsScreen.deleteAccountRow`'s, and the weight comes from
                    // placement because there is no destructive colour in this product to reach
                    // for.
                    if shown != nil {
                        SettingsCard {
                            SettingsActionRow(label: "Remove photo") { confirmingRemove = true }
                        }
                        .padding(.top, 28)
                    }

                    if processingFailed {
                        // Inline and quiet, in the shape `CredentialsSheet` uses. Never an alert:
                        // the parent picked an image the phone could not read, and the answer is
                        // to pick another one.
                        Text(ChildPhotoCopy.unreadable)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Layout.screenMargin)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.canvas)
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // **Done, and no Cancel.** Everything on this sheet has already happened by the
                // time it is on screen — the crop is on disk, the removal is gone — so a Cancel
                // would be a button that undoes nothing while appearing to offer it.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.terracotta)
                }
            }
        }
        // No detents, matching `EditChildSheet` and `CredentialsSheet` — the three sheets this
        // screen's one `.sheet(item:)` presents should not open to three different heights.
        .task(id: pick) { await load(pick) }
        .photosPicker(isPresented: $showingPicker, selection: $pick, matching: .images, photoLibrary: .shared())
        #if canImport(UIKit)
        .sheet(isPresented: $showingCamera) {
            CameraPicker { data in process(data) }
        }
        #endif
        .confirmationDialog(
            "Remove this photo?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            // The one place red is allowed in this product, and it is the system's red rather
            // than one we drew — the same note `DeleteAccountSheet` makes.
            Button("Remove", role: .destructive) { remove() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(ChildPhotoCopy.removeDetail(childName))
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        processingFailed = false
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            processingFailed = true
            return
        }
        process(data)
    }

    /// HEIC in, square JPEG out. `AvatarCrop` is the one crop path in the app and is not
    /// reimplemented here; it is main-actor isolated, so this is called from the view rather than
    /// from a detached task.
    private func process(_ data: Data) {
        do {
            let jpeg = try AvatarCrop.square(data)
            shown = jpeg
            processingFailed = false
            onChoose(jpeg)
        } catch {
            // All three of `AvatarCrop`'s failures — unreadable, not an image, encoding failed —
            // are the same fact to a parent: this picture will not do, try another.
            processingFailed = true
        }
    }

    /// Stays on the sheet. The disc reverting to the glyph and the row disappearing is the whole
    /// feedback; dismissing as well would take the parent somewhere they did not ask to go.
    ///
    /// **`pick` is cleared, and that is not tidying.** `.task(id: pick)` fires on *change*, so a
    /// parent who removes a photo and then picks the same one again from the library selects an
    /// identical `PhotosPickerItem`, the id does not move, the task never runs, and the tap does
    /// nothing at all. `AvatarStep` clears it in its own Remove for exactly this reason. Setting it
    /// to nil does re-run the task, which `load` returns straight out of.
    private func remove() {
        shown = nil
        pick = nil
        processingFailed = false
        onRemove()
    }
}

/// The words, held where a test can read them — the reason `DeleteAccountCopy` exists.
///
/// Every claim here is one the app can keep. In particular **nothing says the photo is deleted from
/// the server or from the phone's photo library**, because neither is true: clearing
/// `children.avatar_key` orphans the object in the bucket, and the original is still in the
/// library exactly where the parent chose it from.
nonisolated enum ChildPhotoCopy {
    /// Already true and already shipped in `AvatarStep`'s subtitle. Kept identical so the two
    /// surfaces make the same promise in the same words.
    static let subtitle = "It's saved with the archive, so a new phone still has it."

    /// Names the child rather than using a pronoun, per the tone rules — client-side strings never
    /// assume a child's gender. Says what the parent will see instead, and stops there: it does not
    /// warn, does not say "permanent", and does not ask whether they are sure beyond the title.
    static func removeDetail(_ childName: String) -> String {
        "\(childName)'s initial comes back in its place. You can add another photo any time."
    }

    static let unreadable = "That image couldn't be read. Try another."
}

/// The round photo preview, at the size onboarding draws it.
///
/// Lifted out of `AvatarStep` so there is one preview circle rather than two that drift. It is
/// deliberately **not** `ChildHeroCard`'s 56pt disc: that one keeps its ring and its frame outside
/// both branches so a late-arriving avatar cannot resize the circle it lands in, which is a rule
/// about a card that renders before its picture does. This one is only ever handed bytes it already
/// has.
/// **One size, and no parameter for it.** Both callers draw it at 132 and the extraction is a pure
/// move — a `size` parameter would have meant deriving the glyph from a ratio, and the nearest
/// clean ratio to 46/132 lands a fraction of a point off the circle onboarding already ships.
/// Changing a shipped screen by a rounding error to gain an argument nobody passes is not a trade.
struct AvatarDisc: View {
    var data: Data?

    private let size: CGFloat = 132

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.terracottaSoft)
                .overlay(Circle().strokeBorder(Color.border, lineWidth: Layout.borderWidth))

            #if canImport(UIKit)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                placeholderGlyph
            }
            #else
            placeholderGlyph
            #endif
        }
        .frame(width: size, height: size)
        // Decoration around a state the rows already announce. Labelling it separately would make
        // VoiceOver say "photo" twice on a screen with one photo.
        .accessibilityHidden(true)
    }

    private var placeholderGlyph: some View {
        Image(systemName: "person.crop.circle")
            .font(.system(size: 46, weight: .light))
            .foregroundStyle(Color.terracotta)
    }
}
