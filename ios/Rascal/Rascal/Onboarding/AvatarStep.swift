import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The fourth step, and the only optional one.
///
/// **A skipped avatar is a complete onboarding, not a deficient one.** Both buttons move on; the
/// only difference is whether a picture comes with it. Nothing here nags, and there is no second
/// ask later.
///
/// The child used to be created here. It is now created at the end of `NotificationStep`, which
/// became the last step — see `OnboardingSession.finishSetup`. The reason it moved rather than
/// staying put is that `finish(with:)` sets `.ready` and lands the parent on Today immediately,
/// so a step after the create would never have been shown.
struct AvatarStep: View {
    @Bindable var session: OnboardingSession

    @State private var pick: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var processingFailed = false

    private var name: String {
        let trimmed = session.draft.trimmedName
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    var body: some View {
        OnboardingStepScaffold(
            title: "Add a photo of \(name)?",
            // **"It stays on this phone for now" was true until this phase and is not now.**
            // The same false-sentence problem as `AvatarStore`'s header comment, in the one place
            // a parent actually reads it — a promise about where a picture of their child is kept
            // is not a detail to leave stale.
            subtitle: "Optional. It's saved with the archive, so a new phone still has it."
        ) {
            VStack(spacing: 20) {
                preview

                HStack(spacing: 10) {
                    photoPicker

                    #if canImport(UIKit)
                    // Hidden where there is no camera — a button that opens nothing is worse
                    // than an absent one, and the simulator has no camera at all.
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showingCamera = true } label: {
                            Text("Take one")
                                .typeRole(.body)
                                .foregroundStyle(Color.terracotta)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
                        }
                        .accessibilityLabel("Take a photo")
                    }
                    #endif
                }

                if processingFailed {
                    OnboardingNotice(message: "That image couldn't be read. Try another.")
                }
            }
            .frame(maxWidth: .infinity)
        } footer: {
            VStack(spacing: 6) {
                if let notice = session.notice {
                    OnboardingNotice(message: notice) {
                        session.advance()
                    }
                    .padding(.bottom, 6)
                }

                Button(session.avatar == nil ? "Continue" : "Save and continue") {
                    session.advance()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(session.isWorking)

                if session.avatar == nil {
                    OnboardingSecondaryButton(title: "Skip for now") {
                        session.advance()
                    }
                    .disabled(session.isWorking)
                } else {
                    OnboardingSecondaryButton(title: "Remove photo") {
                        session.avatar = nil
                        pick = nil
                    }
                    .disabled(session.isWorking)
                }
            }
        }
        .task(id: pick) { await load(pick) }
        #if canImport(UIKit)
        .sheet(isPresented: $showingCamera) {
            CameraPicker { data in process(data) }
        }
        #endif
    }

    /// The title is read into a local before the label closure, which `PhotosPicker` takes as
    /// `@Sendable` — touching a main-actor property from inside it is a concurrency warning, and
    /// this lane treats a warning as a defect.
    private var photoPicker: some View {
        let title = session.avatar == nil ? "Choose a photo" : "Choose another"
        return PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
            Text(title)
                .typeRole(.body)
                .foregroundStyle(Color.terracotta)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .overlay(Capsule().strokeBorder(Color.border, lineWidth: Layout.borderWidth))
        }
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            Circle()
                .fill(Color.terracottaSoft)
                .overlay(Circle().strokeBorder(Color.border, lineWidth: Layout.borderWidth))

            #if canImport(UIKit)
            if let avatar = session.avatar, let image = UIImage(data: avatar) {
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
        .frame(width: 132, height: 132)
        // The circle is decoration around a state the buttons already announce. Labelling it
        // separately would make VoiceOver say "photo" twice on a screen with one photo.
        .accessibilityHidden(true)
    }

    private var placeholderGlyph: some View {
        Image(systemName: "person.crop.circle")
            .font(.system(size: 46, weight: .light))
            .foregroundStyle(Color.terracotta)
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

    /// HEIC in, square JPEG out. The conversion is `ImagePipeline`'s and is not reimplemented —
    /// `AvatarCrop` adds the crop and the downsample and nothing else.
    private func process(_ data: Data) {
        do {
            session.avatar = try AvatarCrop.square(data)
            processingFailed = false
        } catch {
            processingFailed = true
        }
    }
}
