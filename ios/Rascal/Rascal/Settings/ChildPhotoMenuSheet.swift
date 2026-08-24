import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// What the parent picked off the photo menu. Reported to `ChildPhotoField`, which acts on it once
/// the sheet has finished dismissing — see the `onDismiss` there.
nonisolated enum ChildPhotoChoice {
    case library
    case camera
    case remove
}

/// The three ways to change a child's photo, opened from the photo row.
///
/// **A sheet with cards, not a `.confirmationDialog` and not a `Menu`.** `ChildSwitcherSheet` and
/// `AddToArchiveSheet` are the two to compare against and this borrows their measured-height detent
/// for the same reason: three rows are far under half a screen and `.medium` would open a gulf of
/// empty cream under them. A confirmation dialog was the obvious candidate and is wrong twice over
/// — it renders in the system's vocabulary rather than this one, and the only way it can set
/// `Remove photo` apart is `.destructive`, which draws it red. **There is no red in this palette**,
/// and the whole argument for moving Remove out of the field was that colour was never going to be
/// the thing that held it apart.
///
/// **Distance carries it instead.** Choose and Take are two ways to *set* a photo and share one
/// card; Remove is not a third and gets its own, with whitespace above it rather than a divider —
/// the rule `SettingsScreen.deleteAccountRow` already follows, that rows sitting together say
/// "these belong together".
///
/// **A bottom sheet rather than a popover on the avatar**, because the row sits high on this screen
/// and a menu anchored to it would open at the top of a phone held in one hand.
///
/// **No Cancel row.** The import draws one, in the action-sheet idiom it is borrowing from; this app
/// dismisses a sheet by dragging it, says so with `presentationDragIndicator`, and neither of the
/// two sheets this is modelled on carries a Cancel of its own.
struct ChildPhotoMenuSheet: View {
    let childName: String
    /// There is a photo to remove. False hides the second card entirely rather than disabling it —
    /// a row that cannot do anything is a row that should not be drawn.
    let canRemove: Bool
    let onChoose: (ChildPhotoChoice) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Seeded near the real height for the common case — header, two rows, and the remove card — so
    /// the first frame is within a few points of the measurement that replaces it.
    /// `ChildSwitcherSheet` explains the reasoning at length; the number differs because the
    /// content does.
    @State private var contentHeight: CGFloat = 330

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.canvas)
        .presentationDragIndicator(.visible)
        .presentationDetents([.height(contentHeight), .large])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ChildPhotoCopy.menuTitle(childName))
                    .typeRole(.title)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // **Said here rather than discovered later.** The framing step is the one thing
                // about this flow a parent cannot see coming, and a picker that hands off to
                // another screen without warning reads as a step that went wrong.
                Text(ChildPhotoCopy.menuSubtitle)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 14)

            SettingsCard {
                actionRow(ChildPhotoCopy.chooseFromLibrary, choice: .library)

                #if canImport(UIKit)
                // Hidden where there is no camera — the same gate `AvatarStep` uses, and for its
                // reason: a button that opens nothing is worse than an absent one, and the
                // simulator has no camera at all.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    SettingsDivider()
                    actionRow(ChildPhotoCopy.takeAPhoto, choice: .camera)
                }
                #endif
            }

            if canRemove {
                SettingsCard {
                    actionRow(ChildPhotoCopy.removePhoto, choice: .remove)
                }
                .padding(.top, 20)
            }
        }
        .padding(20)
    }

    /// `SettingsActionRow`'s shape and its `terracottaDeep` label, which is a WCAG fix rather than a
    /// preference: `terracotta` `#C05A2B` on `surface` `#FFFDF9` measures 4.36:1 and these labels
    /// are 16pt regular, which is not WCAG large text. `SettingsMembershipTests` scans this
    /// directory for the regression.
    ///
    /// Written out rather than reaching for `SettingsActionRow` itself, because that row reports
    /// progress with an `isBusy` spinner and none of these three has any: each one closes this
    /// sheet and opens something else.
    private func actionRow(_ label: String, choice: ChildPhotoChoice) -> some View {
        Button {
            onChoose(choice)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(label)
                    .typeRole(.body)
                    .foregroundStyle(Color.terracottaDeep)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            .padding(Layout.cardPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityAddTraits(.isButton)
    }
}
