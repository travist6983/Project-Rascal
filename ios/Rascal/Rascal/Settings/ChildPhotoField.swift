import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The child's photo, as the first field of `EditChildSheet`.
///
/// **This was `ChildPhotoSheet` for one phase.** Phase 115 put it behind a `Photo` row in the
/// archive card that opened a modal of its own; phase 117 moved it here on the owner's call of
/// Aug 23, 2026. Every other thing about a child is edited on one sheet, and the photo — the most
/// identifying of the five — was the one thing two taps and a second modal away from the name it
/// belongs beside.
///
/// **The objection phase 115 raised is real and is answered rather than dropped.** That phase held
/// the photo out of this sheet because `EditChildSheet`'s Save is gated on `EditChildModel.canSave`
/// — the four text fields — so a photo applied on the tap would sit under a disabled Save beside a
/// Cancel that could not undo it. There were two ways out and the second is worse:
///
/// 1. **Say so**, in one `metadata` line under the rows, in the vocabulary `timezoneField` already
///    uses for the same job. The parent is told which half of this screen answers to Save. That is
///    `ChildPhotoCopy.savesOnItsOwn`, and the test suite holds it to the tone rules.
/// 2. Hold the crop in the sheet and write it on Save. **Rejected.** `AvatarSync.enqueue` writes to
///    disk *unconditionally* and owes the server on the next sweep, and that is the whole
///    invariant — a picture the parent has already seen never depends on a network call. Gating it
///    on a `PATCH` of four unrelated columns would mean a failed name edit loses a photo.
///
/// **Nothing here has an upload state, including the removal.** `docs/design-system.md`: "The
/// avatar has no upload state, and that is the design." The crop is written to disk and on screen
/// before anything touches the network, and a removal deletes the file on the tap; the server is
/// told on the ordinary foreground sweep.
struct ChildPhotoField: View {
    /// For the removal dialog's message, which names the child rather than using a pronoun.
    ///
    /// **The saved name, not `model.name`.** The name field sits directly below this one and is
    /// live, so binding the dialog to it would ask "Milo's initial comes back" about a child called
    /// `Mil` while somebody is mid-edit.
    let childName: String
    /// A 512px square JPEG, already through `AvatarCrop`. The caller enqueues it.
    let onChoose: (Data) -> Void
    let onRemove: () -> Void

    /// What this field is showing. Seeded from the caller's bytes **in `init`, and never again** —
    /// phase 115's bug, kept fixed: `shown` is legitimately nil after a removal, so any later reseed
    /// under a `shown == nil` guard puts the removed photo back on screen with its Remove row.
    /// `SettingsScreen` builds `EditChildSheet` fresh from `.sheet(item:)` on each presentation, so
    /// this runs exactly once per presentation even though the enclosing sheet's body re-evaluates
    /// on every keystroke in the name field.
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
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Photo")

            // Left-aligned rather than centred, unlike the sheet this replaced: every other field
            // on this screen starts at the margin, and one centred element in a left-aligned form
            // reads as a mistake rather than as emphasis.
            AvatarDisc(data: shown)

            VStack(spacing: 8) {
                actionRow(shown == nil ? "Choose a photo" : "Choose another") {
                    showingPicker = true
                }

                #if canImport(UIKit)
                // Hidden where there is no camera — the same gate `AvatarStep` uses, and for its
                // reason: a button that opens nothing is worse than an absent one, and the
                // simulator has no camera at all.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    actionRow("Take a photo") { showingCamera = true }
                }
                #endif
            }
            .padding(.top, 4)

            // **Whitespace above it rather than another 8pt gap.** The rule `ChildPhotoSheet`
            // carried over from `SettingsScreen.deleteAccountRow`: rows sitting together say "these
            // belong together", and Choose and Take are two ways to set a photo where Remove is not
            // a third. The weight comes from placement because there is no destructive colour in
            // this product to reach for.
            if shown != nil {
                actionRow("Remove photo") { confirmingRemove = true }
                    .padding(.top, 20)
            }

            Text(ChildPhotoCopy.savesOnItsOwn)
                .typeRole(.metadata)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            if processingFailed {
                // Inline and quiet, in the shape `CredentialsSheet` uses. Never an alert: the parent
                // picked an image the phone could not read, and the answer is to pick another one.
                Text(ChildPhotoCopy.unreadable)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
            // The one place red is allowed in this product, and it is the system's red rather than
            // one we drew — the same note `DeleteAccountSheet` makes.
            Button("Remove", role: .destructive) { remove() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(ChildPhotoCopy.removeDetail(childName))
        }
    }

    /// The sheet's own control shape — 12pt padding, `surface`, `mediaInsetRadius`, a `border`
    /// hairline — which `nameField`, `pronounRow` and `timezoneField` each write out beside this
    /// one. Matched deliberately rather than reaching for `SettingsActionRow`: that row is a list
    /// row with a card's padding, and it would be the only one of its shape on this screen.
    ///
    /// **`terracottaDeep`, not `terracotta`.** This is `.typeRole(.body)` — 16pt regular, which is
    /// not WCAG large text — and `terracotta` measures 4.36:1 on `surface` against a 4.5:1 bar.
    /// `RascalTests/SettingsMembershipTests.swift` scans this directory for the regression.
    private func actionRow(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(label)
                    .typeRole(.body)
                    .foregroundStyle(Color.terracottaDeep)
                Spacer(minLength: 8)
            }
            .padding(12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityAddTraits(.isButton)
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

    /// The disc reverting to the glyph and the row disappearing is the whole feedback.
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
    /// **The one sentence this field exists to say out loud.** The photo is written to disk and
    /// owed to the server on the tap; the four fields below it wait for Save. Two behaviours on one
    /// screen is fine — a screen that does not admit to it is not.
    ///
    /// It says nothing about Cancel by name. Cancel is not on the toolbar after a save has landed —
    /// `EditChildSheet.hasSaved` replaces it with Done — and a line naming a button that is
    /// sometimes absent is a line that is sometimes wrong.
    static let savesOnItsOwn = "Photos save on their own, the moment you choose one. The other fields wait for Save."

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
