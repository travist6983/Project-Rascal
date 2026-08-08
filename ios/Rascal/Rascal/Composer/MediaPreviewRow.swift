import SwiftUI

/// The chosen photos, in a white inset frame with rounded corners.
///
/// Photos sit inset with padding rather than bleeding to the screen edge — the design system
/// is explicit about that, and full-bleed photo cards are on the rejected list.
struct MediaPreviewRow: View {
    let drafts: [MediaDraft]
    let onRemove: (MediaDraft) -> Void
    let onAddMore: () -> Void

    /// Past this, the rest collapse into a `+N` tile. Four fits a phone width at this size
    /// without the tiles becoming too small to recognise a face in.
    private let visibleLimit = 4

    private var visible: [MediaDraft] { Array(drafts.prefix(visibleLimit)) }
    private var overflow: Int { max(0, drafts.count - visibleLimit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(drafts.count == 1 ? "1 photo" : "\(drafts.count) photos")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(visible) { draft in
                        tile(draft)
                    }
                    if overflow > 0 { overflowTile }
                    addMoreTile
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    private func tile(_ draft: MediaDraft) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = draft.image {
                    image.resizable().scaledToFill()
                } else {
                    // A draft always has a thumbnail, so this is a should-not-happen. It stays
                    // a neutral surface rather than an error: the photo is staged either way.
                    Color.surface
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )

            Button {
                onRemove(draft)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.surface)
                    .padding(5)
                    .background(Color.ink.opacity(0.55), in: Circle())
            }
            .buttonStyle(TapScaleButtonStyle())
            .padding(5)
            .accessibilityLabel("Remove this photo")
        }
        .accessibilityElement(children: .contain)
    }

    private var overflowTile: some View {
        Text("+\(overflow)")
            .typeRole(.cardTitle)
            .foregroundStyle(Color.inkMuted)
            .frame(width: 84, height: 84)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: Layout.borderWidth)
            )
            .accessibilityLabel("\(overflow) more photos")
    }

    private var addMoreTile: some View {
        Button(action: onAddMore) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.terracotta)
                .frame(width: 84, height: 84)
                .background(Color.terracottaSoft, in: RoundedRectangle(cornerRadius: Layout.mediaInsetRadius, style: .continuous))
        }
        .buttonStyle(TapScaleButtonStyle())
        .accessibilityLabel("Add another photo")
    }
}

#if canImport(UIKit)
import UIKit

/// The camera. `PhotosPicker` covers the library; this covers the other entry point.
///
/// `UIImagePickerController` rather than an `AVCaptureSession`: capture must cost under fifteen
/// seconds one-handed, and the system camera is the one every parent already knows how to use.
/// Building a custom viewfinder would be slower to reach and worse to operate.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let dismiss: () -> Void

        init(onCapture: @escaping (Data) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // Full quality out of the camera. The pipeline does the compressing, so that the
            // camera and library paths produce identical bytes.
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 1.0) {
                onCapture(data)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
#endif
