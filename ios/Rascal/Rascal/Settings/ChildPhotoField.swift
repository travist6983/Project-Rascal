import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The child's photo, as **one row** of `EditChildSheet` — and the row is the only control.
///
/// **This was three stacked rows for one phase.** Phase 117 moved the photo onto this sheet as a
/// 132pt disc above `Choose a photo` / `Take a photo` / `Remove photo`; phase 118 collapses all of
/// it into a single row that sits with Name and Birthday, on the owner's call of Aug 23, 2026 and
/// the design import's argument:
///
/// 1. **Three rows, one weight, and one of them removes.** Remove sat in the same `terracottaDeep`
///    as Choose another, at the same width, one thumb away, with 20pt of whitespace as the only
///    thing holding it apart. A gap is not a safeguard. The three ways *in* are now a menu opened
///    on purpose, and Remove is a separate card inside it.
/// 2. **The largest thing on the screen did nothing.** A 132pt disc with three text rows underneath
///    is a picture with a menu bolted to it. Tapping the row — the picture included — is the whole
///    interaction now, and the rows only exist once they have been asked for.
/// 3. **A circle crop of a landscape photo is a bad photo.** A child sitting in the left third came
///    out as grass, because `AvatarCrop.square` centre-crops and nothing ever showed the parent
///    where the crop fell. Choosing now hands off to `AvatarFramingScreen`, once, with the circle
///    drawn where the crop actually lands.
/// 4. **A whole section for one optional field.** Name, birthday, pronouns and timezone are on this
///    sheet; the photo is the same kind of fact and now takes the same amount of room as one of
///    them rather than four screens' worth.
///
/// **What phase 117 settled is kept and is not relitigated.** `AvatarSync.enqueue` still writes to
/// disk and owes the server unconditionally, so the photo lands on the tap while the four fields
/// below it wait for Save — and `ChildPhotoCopy.savesOnItsOwn` still says so out loud. The import
/// draws this field as *"takes effect when you save"* with the undo held until then; that is the
/// alternative `docs/design-system.md` records as rejected, because gating a picture on a `PATCH` of
/// four unrelated columns means a failed name edit loses a photo. **Undo here is real instead of
/// deferred**: it re-enqueues the bytes the sheet opened with, which `AvatarSync` accepts as the
/// last intent for that child.
///
/// **Nothing here has an upload state, and the import's three are deliberately not built.**
/// `docs/design-system.md`: *"The avatar has no upload state, and that is the design."* The crop is
/// on disk and on screen before anything touches the network, and a removal deletes the file on the
/// tap; the server is told on the ordinary foreground sweep. A progress ring over a picture the
/// parent can already see is an animation about something that has finished.
struct ChildPhotoField: View {
    /// For the row's own copy, which names the child rather than using a pronoun.
    ///
    /// **The saved name, not `model.name`.** The name field sits below this one and is live, so
    /// binding this to it would say "Mil's initial stands in again" while somebody is mid-edit.
    let childName: String
    /// A 512px square JPEG, already through `AvatarCrop`. The caller enqueues it.
    let onChoose: (Data) -> Void
    let onRemove: () -> Void

    /// What this field is showing. Seeded from the caller's bytes **in `init`, and never again** —
    /// phase 115's bug, kept fixed: `shown` is legitimately nil after a removal, so any later reseed
    /// under a `shown == nil` guard puts the removed photo back on screen. `SettingsScreen` builds
    /// `EditChildSheet` fresh from `.sheet(item:)` on each presentation, so this runs exactly once
    /// per presentation even though the enclosing sheet's body re-evaluates on every keystroke.
    @State private var shown: Data?

    /// What Undo puts back, and nil when there is nothing to undo.
    ///
    /// **Captured from `shown` at the moment the parent first changes something, never seeded from
    /// the caller.** Phase 117 removed the incoming bytes as a property on the grounds that with
    /// nothing stale to read back the reseed bug is unavailable rather than merely fixed, and that
    /// still holds: this is nil until the parent themselves creates it, and it is only ever written
    /// from what was on screen at that instant.
    ///
    /// It is captured **once per undo**, so Undo means "back to the last picture that was on the
    /// name" rather than "back one step" — a parent who removes a photo and then picks a different
    /// one still has the original one tap away, which a one-step undo would have spent. On a sheet
    /// opened with a photo that is the same thing as "back to how it opened"; on one opened without
    /// it is the photo they added and then took off, which is the only thing there is to go back
    /// to. **Adding the first photo offers no undo at all**, deliberately: Remove is right there in
    /// the menu, and a pill that undid an addition would be a second word for it.
    @State private var undoTarget: Data?

    @State private var showingMenu = false
    /// What the parent picked off the menu, held until the menu has finished dismissing. See the
    /// `onDismiss` on the sheet.
    @State private var choice: ChildPhotoChoice?
    @State private var pick: PhotosPickerItem?
    @State private var showingPicker = false
    @State private var showingCamera = false
    /// Bytes that have arrived but whose framing screen cannot be presented yet, because whatever
    /// produced them is still on screen. See `presentFraming`.
    @State private var pendingPhoto: Data?
    @State private var framing: AvatarFramingRequest?
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
            row

            // Where it does *not* appear, which is the half the row's subtitle cannot carry, and
            // the two-save-behaviours line phase 117 exists to say out loud. Two sentences about
            // two different things rather than one about neither.
            VStack(alignment: .leading, spacing: 6) {
                Text(ChildPhotoCopy.footnote)
                Text(ChildPhotoCopy.savesOnItsOwn)

                if processingFailed {
                    // Inline and quiet, in the shape `CredentialsSheet` uses. Never an alert: the
                    // parent picked an image the phone could not read, and the answer is another
                    // picture rather than a dialog to dismiss first.
                    Text(ChildPhotoCopy.unreadable)
                }
            }
            .typeRole(.metadata)
            .foregroundStyle(Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
        }
        .task(id: pick) { await load(pick) }
        .photosPicker(isPresented: $showingPicker, selection: $pick, matching: .images, photoLibrary: .shared())
        #if canImport(UIKit)
        // **`onDismiss`, and this one is not a precaution — it is a guaranteed conflict without
        // it.** `CameraPicker.Coordinator` calls `onCapture` and *then* `dismiss()`, in that order,
        // so bytes arrive while the camera sheet is unambiguously still presented. The app's two
        // existing callers only mutate state from that closure and never noticed; this one opens a
        // `fullScreenCover`, and a cover presented over a live sheet is the presentation UIKit
        // drops on the floor.
        .sheet(isPresented: $showingCamera, onDismiss: presentFraming) {
            CameraPicker { data in pendingPhoto = data }
        }
        #endif
        // **The menu reports a choice and the parent acts once it has gone**, rather than the rows
        // calling straight through. Every row on it opens something else — the library, the
        // camera — and a presentation started in the same update that dismisses the sheet
        // underneath it is the presentation UIKit silently drops. `onDismiss` is the one moment
        // both are true: this sheet is gone, and nothing else is on screen yet.
        .sheet(isPresented: $showingMenu, onDismiss: runChoice) {
            ChildPhotoMenuSheet(
                childName: childName,
                canRemove: shown != nil,
                onChoose: { choice = $0 }
            )
        }
        // The library's half of the same seam. `.photosPicker` has no `onDismiss`, so the binding
        // going false is the signal — and either ordering is safe, because `presentFraming` is
        // called from both ends and refuses until nothing else is on screen.
        .onChange(of: showingPicker) { _, isShowing in
            if !isShowing { presentFraming() }
        }
        // **A cover, not a sheet.** The photo has to be judged against a dark surround at the size
        // it will be cropped to, and a sheet leaves a strip of cream at the top of the one screen
        // in this flow that is drawn on ink.
        .fullScreenCover(item: $framing) { request in
            AvatarFramingScreen(request: request) { jpeg in
                finishFraming()
                apply(jpeg)
            } onCancel: {
                finishFraming()
            }
        }
    }

    // MARK: The row

    /// One field among fields, in this sheet's own control shape — 12pt padding, `surface`,
    /// `mediaInsetRadius`, a `border` hairline — which `nameField`, `pronounRow` and
    /// `timezoneField` each write out beside it.
    ///
    /// **No `SectionLabel("Photo")` above it.** Every other field on this sheet is a label over a
    /// control that cannot name itself; this row's own first line is the label, and it changes with
    /// the state — "Photo", "Add a photo", "Photo removed". A section label above it would read
    /// "Photo / Photo" in the ordinary case and would be flatly wrong in the other two.
    private var row: some View {
        outerLayout {
            Button { showingMenu = true } label: {
                innerLayout {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .typeRole(.body)
                            .foregroundStyle(shown == nil && undoTarget == nil ? Color.terracottaDeep : Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .typeRole(.metadata)
                            .foregroundStyle(Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // **Dropped at the accessibility sizes**, where the disc is 160pt and the two
                    // lines beside it are 50, and a 13pt glyph competing for width is what turns
                    // "Shown beside Milo's name" into "Show / n / besid / e". `SettingsRow`'s own
                    // note is that this chevron carries nothing VoiceOver needs; the row keeps its
                    // button trait, and the terracotta badge on the disc is the affordance that
                    // survives at any size.
                    if undoTarget == nil && !isAccessibilitySize {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapScaleButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(subtitle)")
            .accessibilityHint(ChildPhotoCopy.openHint)
            .accessibilityAddTraits(.isButton)

            if undoTarget != nil { undoButton }
        }
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.mediaInsetRadius)
                .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
        )
    }

    /// The disc, and the badge that says it is a control.
    ///
    /// The badge is an offer to change the photo, so it is absent in the one state that is already
    /// offering something else — the removed row, whose trailing element is Undo. While the menu is
    /// open the badge is replaced by a `terracotta` ring, so the sheet's scrim does not leave the
    /// thing the menu is about looking like ordinary dimmed content.
    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            AvatarDisc(name: childName, data: shown, size: discSize)
                .overlay {
                    if showingMenu {
                        Circle()
                            .strokeBorder(Color.terracotta, lineWidth: 2)
                            .padding(-3)
                    }
                }

            if undoTarget == nil && !showingMenu {
                Image(systemName: "plus")
                    .font(.system(size: badgeSize * 0.5, weight: .regular))
                    .foregroundStyle(Color.canvas)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Color.terracotta, in: Circle())
                    .overlay(Circle().strokeBorder(Color.surface, lineWidth: 2.5))
                    .offset(x: 3, y: 3)
            }
        }
        // The disc and its badge are decoration around a state the row's own two lines announce.
        // Labelling them would make VoiceOver say "photo" three times on a row about one photo.
        .accessibilityHidden(true)
    }

    private var undoButton: some View {
        Button {
            guard let bytes = undoTarget else { return }
            shown = bytes
            undoTarget = nil
            processingFailed = false
            onChoose(bytes)
        } label: {
            Text(ChildPhotoCopy.undo)
                .typeRole(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(Color.terracottaDeep)
                .padding(.horizontal, 16)
                // 44pt of height, which is the tap target rather than the drawn pill — the pill is
                // the text and this is the room around it.
                .frame(minHeight: 44)
                .background(Color.terracottaSoft, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel(
            shown == nil
                ? ChildPhotoCopy.undoRemoval(childName)
                : ChildPhotoCopy.undoChange(childName)
        )
    }

    /// 64pt, and it grows with the two lines beside it — the same rule `ChildHeroCard`'s disc
    /// follows, for the same reason: a fixed circle next to 40pt text is a bullet point.
    @ScaledMetric(relativeTo: .body) private var discSize: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 26

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    /// **The row stops being a row at the accessibility sizes, and it has to.** The disc scales to
    /// about 160pt there and the text beside it to about 50, which leaves roughly 150pt of column
    /// for two sentences — so the words break inside themselves and the field reads as broken
    /// rather than as large. Stacked, every line gets the full width and nothing truncates.
    ///
    /// `AnyLayout` rather than an `if` over two whole subtrees: the children keep their identity
    /// across the switch, so a size change animates and the button does not lose its pressed state
    /// mid-gesture. The same reason `PromptCard`'s footer stacks rather than shrinks.
    private var innerLayout: AnyLayout {
        isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 14))
    }

    /// Undo goes under the row at the accessibility sizes rather than beside it, for the reason
    /// above and one more: a 44pt pill and a 160pt disc on one line leave the pill looking like a
    /// caption on the picture.
    private var outerLayout: AnyLayout {
        isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    private var title: String {
        if shown != nil { return ChildPhotoCopy.rowTitle }
        return undoTarget == nil ? ChildPhotoCopy.addTitle : ChildPhotoCopy.removedTitle
    }

    /// **Four states, and the fourth is the one that is easy to leave out.** A parent who replaced a
    /// photo sees a row that looks exactly like an unchanged one, with an `Undo` pill beside it and
    /// nothing saying what it would undo. `ChildPhotoCopy.changed` is that sentence; the pill's
    /// VoiceOver label carries the same fact for anybody not reading it.
    private var subtitle: String {
        if shown != nil {
            return undoTarget == nil ? ChildPhotoCopy.appearsIn(childName) : ChildPhotoCopy.changed
        }
        return undoTarget == nil
            ? ChildPhotoCopy.standsIn(childName)
            : ChildPhotoCopy.removed(childName)
    }

    // MARK: Acting

    private func runChoice() {
        guard let choice else { return }
        self.choice = nil
        switch choice {
        case .library: showingPicker = true
        case .camera: showingCamera = true
        case .remove: remove()
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        processingFailed = false
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            processingFailed = true
            return
        }
        pendingPhoto = data
        presentFraming()
    }

    /// Open the framing screen, once whatever produced the bytes has gone.
    ///
    /// **Called from three places and correct in whichever order they fire.** The library sets
    /// `pendingPhoto` after an await and the camera sets it before its own dismissal, so neither
    /// path can be relied on to be the last event — the guard is what decides, not the caller.
    private func presentFraming() {
        guard !showingPicker, !showingCamera, let data = pendingPhoto else { return }
        pendingPhoto = nil
        framing = AvatarFramingRequest(data: data)
    }

    /// Close the framing cover and release the picked item.
    ///
    /// **`pick` is cleared on both outcomes, and it is not tidying.** `.task(id: pick)` fires on
    /// *change*, so a parent who frames a photo and then reaches for the same one again — which
    /// `ChildPhotoCopy.framingDetail` explicitly offers as the way to reframe it — selects an
    /// identical `PhotosPickerItem`, the id does not move, the task never runs, and the tap does
    /// nothing at all. The same trap `AvatarStep` and `remove()` clear it for, on the path where it
    /// is easiest to miss: the picture is already on the name, so the second tap looks like it
    /// simply had nothing to do.
    private func finishFraming() {
        framing = nil
        pick = nil
    }

    /// The framed 512px square, on the name and owed to the server.
    private func apply(_ jpeg: Data) {
        capture()
        shown = jpeg
        processingFailed = false
        onChoose(jpeg)
    }

    /// **No confirmation alert, and that is the call the import argues hardest for.**
    ///
    /// Phase 115 added the dialog on one specific ground, and it is the only one that ever held: a
    /// photo taken through `CameraPicker` is never written to the photo library, so for that path
    /// the crop genuinely is the only copy, and this field cannot know which path produced the
    /// picture it is about to drop. **That is answered by the `Undo` pill rather than by an alert.**
    /// An undo returns the bytes; an alert only asks the parent to agree in advance that something
    /// is about to be destroyed, which is a worse deal on the exact case it was added for — a
    /// mis-tap past the dialog is unrecoverable and a mis-tap past this one is not.
    ///
    /// Cancel on the toolbar is still there behind it. A third safeguard that interrupts is
    /// theatre, and it teaches the parent that this screen does dangerous things.
    private func remove() {
        capture()
        shown = nil
        // `.task(id: pick)` fires on *change*, so a parent who removes a photo and then picks the
        // same one from the library again selects an identical `PhotosPickerItem`, the id does not
        // move, the task never runs, and the tap does nothing. Setting it to nil does re-run the
        // task, which `load` returns straight out of.
        pick = nil
        processingFailed = false
        onRemove()
    }

    /// Remember what Undo goes back to, the first time the parent changes anything.
    private func capture() {
        guard undoTarget == nil, let bytes = shown else { return }
        undoTarget = bytes
    }
}

/// The words, held where a test can read them — the reason `DeleteAccountCopy` exists.
///
/// Every claim here is one the app can keep, and two of the import's are not:
///
/// - *"Shown beside his name in Timeline and Moments."* The avatar bytes render in exactly two
///   places — `ChildHeroCard` at the top of Settings, and `AvatarStep` during setup. Today's
///   `ChildSwitcherPill` and `ChildSwitcherSheet` draw the initial and never the photo, by
///   `docs/design-system.md`'s own rule that *"the initial is the whole treatment, not a
///   fallback"*, because `GET /children/{id}/today` carries no avatar key. `appearsIn` says
///   Settings, which is where it is.
/// - *"It's never part of an export unless you ask."* There is no such switch. `ArchiveExport`
///   names no avatar at all, so the photo is not in an export, full stop — and `footnote` says the
///   thing that is true rather than the softer thing that is not.
///
/// In particular **nothing says the photo is deleted from the server or from the phone's photo
/// library**, because neither is true: clearing `children.avatar_key` orphans the object in the
/// bucket, and the original is still in the library exactly where the parent chose it from.
nonisolated enum ChildPhotoCopy {
    static let rowTitle = "Photo"
    static let addTitle = "Add a photo"
    static let removedTitle = "Photo removed"

    /// Where it appears. Names the child rather than using a pronoun, per the tone rules — every
    /// client-side string in this app is written so it never assumes a child's gender.
    static func appearsIn(_ childName: String) -> String {
        "Shown beside \(childName)'s name at the top of Settings."
    }

    /// **The empty state is the child's initial, never a grey silhouette**, so this says what
    /// stands in rather than what is missing. A person glyph is the app admitting it has nothing,
    /// on the one screen that is about a specific child — and plenty of households will never add a
    /// photo, so the archive has to look finished for them rather than perpetually incomplete.
    static func standsIn(_ childName: String) -> String {
        "Optional. Until then, \(childName)'s initial stands in."
    }

    /// What happened, stated as a fact and not as a loss. Nothing here warns, says "permanent", or
    /// asks whether the parent is sure.
    static func removed(_ childName: String) -> String {
        "\(childName)'s initial stands in again."
    }

    /// The replaced row, where the picture on screen is already the new one and the only thing
    /// saying so is a pill. Says what changed and what the pill does, in that order.
    static let changed = "Changed. Undo puts the previous one back."

    static let undo = "Undo"

    static func undoRemoval(_ childName: String) -> String {
        "Undo removing \(childName)'s photo"
    }

    static func undoChange(_ childName: String) -> String {
        "Put \(childName)'s previous photo back"
    }

    static let openHint = "Opens the ways to change the photo."

    // MARK: The menu

    static func menuTitle(_ childName: String) -> String { "\(childName)'s photo" }
    static let menuSubtitle = "You'll get to frame it before it's saved."
    static let chooseFromLibrary = "Choose from Photos"
    static let takeAPhoto = "Take a photo"
    static let removePhoto = "Remove photo"

    // MARK: Framing

    static let framingTitle = "Frame the photo"
    static let framingHint = "Drag to move, pinch to zoom."
    /// What the preview *is*, for anyone who cannot see it. The hint says what can be done to it;
    /// this says what it is, because "drag to move" alone describes a gesture on nothing.
    static let framingPreviewLabel = "The photo, with the circle showing what will be kept."
    /// **Not "the full photo is kept".** A 512px square is what gets written; the rest is not
    /// stored anywhere by this app, and the import's line promises a re-framable original that
    /// `AvatarCrop` has never produced. What is true is that the picture is still in the library,
    /// so choosing it again is the way back.
    static let framingDetail = "The circle is what shows on the name. Pick the photo again any time to reframe it."
    static let useThisPhoto = "Use this photo"
    /// The only way out of the framing screen. One word for one action — the import spends two,
    /// `Back` on the header and `Cancel` in the footer, for the same tap.
    static let framingCancel = "Cancel"

    // MARK: The two footnotes

    /// Where it does **not** appear. The row's subtitle says where it does.
    static let footnote = "It isn't a profile picture anywhere, and it isn't part of an export."

    /// **The one sentence this field exists to say out loud.** The photo is written to disk and
    /// owed to the server on the tap; the four fields below it wait for Save. Two behaviours on one
    /// screen is fine — a screen that does not admit to it is not.
    ///
    /// It says nothing about Cancel by name. Cancel is not on the toolbar after a save has landed —
    /// `EditChildSheet.hasSaved` replaces it with Done — and a line naming a button that is
    /// sometimes absent is a line that is sometimes wrong.
    static let savesOnItsOwn = "Photos save on their own, the moment you choose one. The other fields wait for Save."

    static let unreadable = "That image couldn't be read. Try another."
}

/// The round photo preview, and **the child's initial when there is no photo**.
///
/// Lifted out of `AvatarStep` so there is one preview circle rather than two that drift.
///
/// **The `person.crop.circle` glyph is gone, and that is the import's second-loudest argument.** A
/// grey person is the app saying it has nothing, on a screen about a specific child; the monogram
/// is a legitimate avatar and is already what `ChildHeroCard` and Today's pill draw. The initial is
/// `ChildHeroCard.initial(of:)` rather than a fourth copy of the same grapheme walk — that one is
/// tested against combining accents and flag sequences and this inherits all of it.
///
/// The glyph survives for exactly one case: a name with no first grapheme at all, which is
/// reachable in setup before the name step has been answered. A blank circle there would read as a
/// rendering fault, and the glyph is the honest thing to draw when there is genuinely nothing to
/// draw with.
///
/// It is deliberately **not** `ChildHeroCard`'s 56pt disc: that one keeps its ring and its frame
/// outside both branches so a late-arriving avatar cannot resize the circle it lands in, which is a
/// rule about a card that renders before its picture does. This one is only ever handed bytes it
/// already has.
///
/// **`size` is a parameter now**, where phase 117 argued it should not be. That argument was about
/// the *glyph*: the nearest clean ratio to 46/132 landed a fraction of a point off the circle
/// onboarding shipped, and changing a shipped screen by a rounding error to gain an argument nobody
/// passed is not a trade. The glyph is gone, the letter scales cleanly, and there are now two
/// callers at two sizes — 64 in the row, 132 in setup — so the parameter has something to do.
struct AvatarDisc: View {
    /// The child's name, for the initial. The disc derives the letter rather than being handed one,
    /// so no caller can pass a letter that disagrees with the name beside it.
    var name: String
    var data: Data?
    var size: CGFloat = 132

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
                monogram
            }
            #else
            monogram
            #endif
        }
        .frame(width: size, height: size)
        // Decoration around a state the rows already announce. Labelling it separately would make
        // VoiceOver say "photo" twice on a screen with one photo.
        .accessibilityHidden(true)
    }

    /// 0.4 of the diameter, which puts the 64pt row disc on the import's 26pt letter to the digit
    /// and keeps setup's 132pt disc proportional to it.
    @ViewBuilder
    private var monogram: some View {
        let letter = ChildHeroCard.initial(of: name)
        if letter.isEmpty {
            Image(systemName: "person.crop.circle")
                .font(.system(size: size * 0.35, weight: .light))
                .foregroundStyle(Color.terracotta)
        } else {
            Text(letter)
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(Color.terracotta)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }
}
