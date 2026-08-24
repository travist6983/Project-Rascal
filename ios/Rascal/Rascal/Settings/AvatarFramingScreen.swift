import CoreGraphics
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// What `AvatarFramingScreen` is framing. A wrapper rather than the bare `Data` because
/// `fullScreenCover(item:)` needs an `Identifiable`, and because two picks of the same picture must
/// present two covers rather than being deduplicated by their bytes.
struct AvatarFramingRequest: Identifiable {
    let id = UUID()
    let data: Data
}

/// Where the circle falls on the chosen picture, and the arithmetic that turns a drag and a pinch
/// into a crop rectangle.
///
/// **A value type with no view in it, because this is the part that can be wrong silently.** A
/// crop that is off by the height of the header is a photo of somebody's chin, and it looks
/// plausible on every screenshot until you compare it to what the parent framed. The screen draws;
/// this decides; `AvatarFramingTests` pins it.
///
/// Coordinates: the viewport is a square of `viewport` points with the image drawn `scaledToFill`
/// into it, scaled about its centre and then translated. `focus` comes back **normalised to the
/// upright image**, which is the space `AvatarCrop.square(_:focus:)` crops in — both derive that
/// image through `AvatarCrop.upright`, so the orientation transform is baked in on both sides and
/// the rectangle cannot land on a rotated original.
nonisolated struct AvatarFramingGeometry: Equatable {
    /// The upright image, in pixels.
    let imageSize: CGSize
    /// The square the picture is drawn into, in points.
    let viewport: CGFloat

    /// **0.7 of the viewport**, which is the import's 276 on 393 to within a third of a point. The
    /// ring has to leave enough picture visible around it that a parent can see what they are
    /// moving *towards*; a circle at the full width would be a crop with no context.
    static let circleRatio: CGFloat = 0.7

    /// Actual size and 6×. There is no way back from a photo zoomed to a thousandth with one
    /// finger, and the same clamp for the same reason as `MediaViewer`.
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 6

    var circle: CGFloat { viewport * Self.circleRatio }

    /// Points per pixel at rest. `scaledToFill` on a square viewport, so **both** drawn edges are at
    /// least `viewport` — which is why `minScale` of 1 already guarantees the picture covers the
    /// circle and no separate coverage clamp is needed.
    var baseScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(viewport / imageSize.width, viewport / imageSize.height)
    }

    func drawnSize(scale: CGFloat) -> CGSize {
        let factor = baseScale * scale
        return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
    }

    nonisolated static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, scale))
    }

    /// How far the picture may be dragged before an edge of it crosses into the circle.
    ///
    /// Clamped at zero rather than allowed to go negative: a picture narrower than the circle
    /// cannot be reached by this at all, and a negative bound would invert the clamp below and pin
    /// it to the wrong edge.
    func maxOffset(scale: CGFloat) -> CGSize {
        let drawn = drawnSize(scale: scale)
        return CGSize(
            width: max(0, (drawn.width - circle) / 2),
            height: max(0, (drawn.height - circle) / 2)
        )
    }

    /// **The circle is never allowed off the picture.** A parent can drag as far as the edge and
    /// no further, so there is no state in which the saved square is part photograph and part
    /// nothing — which is what a crop rectangle running past the image would encode.
    ///
    /// **It clamps to the circle and deliberately not to the viewport**, so at full drag the ink
    /// shows through the viewport's corners outside the ring. That is not a gap to close: clamping
    /// to the viewport would stop the parent putting a subject near the photo's own edge inside the
    /// circle, which is the exact case — a child in the left third of a landscape frame — that this
    /// whole screen exists for. The scrim reads that background as "outside the crop", which is
    /// what it is.
    func clamped(offset: CGSize, scale: CGFloat) -> CGSize {
        let limit = maxOffset(scale: scale)
        return CGSize(
            width: min(limit.width, max(-limit.width, offset.width)),
            height: min(limit.height, max(-limit.height, offset.height))
        )
    }

    /// The circle's bounding square, in coordinates normalised to the upright image.
    ///
    /// The square rather than the circle: a JPEG is rectangular, `AvatarDisc` clips it to a circle
    /// at every size it draws, and storing the inscribed square instead would mean the disc showed
    /// less than the parent framed.
    func focus(offset: CGSize, scale: CGFloat) -> CGRect {
        // **The degenerate answer is the whole picture, and it is unreachable from `use()`.**
        // `AvatarFramingScreen` builds this geometry once before `prepare()` has decoded anything,
        // so a zero-sized image is a real state for one frame — but the confirming button is
        // disabled in exactly that state, so nothing ever crops from it. Returning the unit rect
        // rather than a guessed square keeps the fallback obviously a fallback: it is the only
        // rectangle this returns that is *not* square in pixels, which is the contract
        // `AvatarCrop.square(_:focus:)` documents.
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let clamped = clamped(offset: offset, scale: scale)
        let drawn = drawnSize(scale: scale)
        // `baseScale` is positive whenever the image is, and `scale` is clamped at 1 — so this is
        // belt and braces against a caller passing a scale the screen cannot produce.
        let factor = baseScale * scale
        guard factor > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        // Where the picture's top-left corner sits inside the viewport.
        let originX = viewport / 2 + clamped.width - drawn.width / 2
        let originY = viewport / 2 + clamped.height - drawn.height / 2
        // The circle's bounding square, in the picture's own pixels.
        let inset = (viewport - circle) / 2
        let x = (inset - originX) / factor
        let y = (inset - originY) / factor
        let side = circle / factor

        return CGRect(
            x: x / imageSize.width,
            y: y / imageSize.height,
            width: side / imageSize.width,
            height: side / imageSize.height
        )
    }
}

/// The step the flow was missing: where the circle actually falls.
///
/// **`AvatarCrop.square` centre-crops, and always has.** A child sitting in the left third of a
/// landscape photo came out as grass, and nothing anywhere told the parent that was going to
/// happen — the picture went straight from the library onto the name. This is one screen, once,
/// with the circle drawn where the crop lands.
///
/// **Drawn on ink, and it is the only screen in this flow that is.** A photograph cannot be judged
/// against cream: the surround has to be darker than anything in the picture or the eye reads the
/// page as part of the composition. `docs/design-system.md`'s rule is that the palette's canvas is
/// never black — this is a viewer, in the vocabulary `MediaViewer` already uses, not a page.
///
/// **One filled terracotta button, which is the one place the rules allow one.** It is the single
/// confirming action on a modal screen with nothing else to do.
struct AvatarFramingScreen: View {
    let request: AvatarFramingRequest
    /// A 512px square JPEG, framed. The caller enqueues it.
    let onUse: (Data) -> Void
    let onCancel: () -> Void

    #if canImport(UIKit)
    @State private var preview: UIImage?
    #endif
    /// The upright pixels, which the geometry is expressed in. Held separately from the preview so
    /// the maths does not depend on a `UIImage` existing on a platform that has none.
    @State private var imageSize: CGSize?
    @State private var unreadable = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    /// The side of the square the picture was actually drawn into, in points. `offset` is measured
    /// in it, so the crop has to be computed in it — see `use()`.
    @State private var drawnViewport: CGFloat = 0

    /// Longest edge of the picture this screen decodes to draw.
    ///
    /// **Not the original and not 512.** Decoding a 24-megapixel photo to put it behind a circle is
    /// the cost `AvatarCrop` was written to avoid, and 512 would be the crop's own resolution
    /// stretched across the whole viewport — visibly soft at 6× on a 3x screen, which is exactly
    /// when a parent is looking closely. 1600 is four times the widest viewport this draws into.
    private static let previewPixels = 1600

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { proxy in
                let side = proxy.size.width
                viewport(side: side)
                    .frame(width: side, height: side)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { drawnViewport = $0 }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text(ChildPhotoCopy.framingHint)
                    .typeRole(.body)
                    .foregroundStyle(Color.canvas.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                Text(unreadable ? ChildPhotoCopy.unreadable : ChildPhotoCopy.framingDetail)
                    .typeRole(.metadata)
                    .foregroundStyle(Color.canvas.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Spacer(minLength: 12)

            useButton
                .padding(.horizontal, 18)
                .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **`ignoresSafeArea` on the background and not on the content.** A `fullScreenCover` lays
        // its content out inside the safe area and paints the rest with the *system's* background,
        // so an ink screen without this renders with a pale band under the notch and another under
        // the home indicator — on the one screen in the app whose whole argument is that a
        // photograph needs a dark surround. The content stays inside the safe area, which is where
        // Cancel and the button belong.
        .background(Color.ink.ignoresSafeArea())
        .task { await prepare() }
    }

    // MARK: Chrome

    /// **One way out, called one thing.** The import draws Back on the header and Cancel in the
    /// footer; they are the same action here — the picker is already gone by the time this opens —
    /// and two words for one button is a claim that they differ.
    ///
    /// **The centred title is a `ZStack` only while it fits.** At the accessibility sizes the title
    /// is about 40pt and Cancel about 38, so a centred overlay lands the two on top of each other
    /// and neither is readable — which is worse than the layout it was trying to preserve. Stacked,
    /// leading-aligned, both are whole.
    @ViewBuilder
    private var header: some View {
        let cancel = Button(ChildPhotoCopy.framingCancel) { onCancel() }
            .typeRole(.body)
            .foregroundStyle(Color.canvas.opacity(0.7))
        let title = Text(ChildPhotoCopy.framingTitle)
            .typeRole(.cardTitle)
            .foregroundStyle(Color.canvas)
            .fixedSize(horizontal: false, vertical: true)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    cancel
                    title
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZStack {
                    title
                    HStack {
                        cancel
                        Spacer(minLength: 8)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var useButton: some View {
        Button {
            use()
        } label: {
            Text(ChildPhotoCopy.useThisPhoto)
                .typeRole(.cardTitle)
                .foregroundStyle(Color.canvas)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.terracotta, in: Capsule())
        }
        .buttonStyle(TapScaleButtonStyle())
        .disabled(imageSize == nil)
        .opacity(imageSize == nil ? 0.5 : 1)
    }

    // MARK: The picture

    @ViewBuilder
    private func viewport(side: CGFloat) -> some View {
        let geometry = AvatarFramingGeometry(imageSize: imageSize ?? .zero, viewport: side)
        let liveScale = AvatarFramingGeometry.clampedScale(scale * pinch)
        let liveOffset = geometry.clamped(
            offset: CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
            scale: liveScale
        )

        ZStack {
            #if canImport(UIKit)
            AvatarFramingPicture(
                image: preview,
                geometry: geometry,
                offset: liveOffset,
                scale: liveScale
            )
            #else
            Color.ink
            #endif

            // The scrim and the ring, drawn as one even-odd path so the hole is exactly the circle
            // the crop uses rather than a mask that has to be kept in step with it.
            cutout(side: side, diameter: geometry.circle)
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    offset = geometry.clamped(
                        offset: CGSize(
                            width: offset.width + value.translation.width,
                            height: offset.height + value.translation.height
                        ),
                        scale: scale
                    )
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    scale = AvatarFramingGeometry.clampedScale(scale * value.magnification)
                    // Re-clamped at the new scale: zooming out shrinks the room to drag in, and an
                    // offset that was legal a moment ago can now put the circle off the picture.
                    offset = geometry.clamped(offset: offset, scale: scale)
                }
        )
        // **Drag and pinch are not reachable under VoiceOver or Switch Control, and this screen is
        // still not a barrier — which is the only reason it ships as it is.** An untouched framing
        // is the centre crop, which is byte-for-byte what `AvatarCrop.square` produced before this
        // screen existed: somebody who cannot pan the picture taps *Use this photo* and gets
        // exactly the avatar every previous build gave them. The gap is that they cannot get a
        // *better* one, and it is recorded in `decisions-log.md` rather than papered over with an
        // adjustable action that could zoom but never pan.
        .accessibilityElement()
        .accessibilityLabel(ChildPhotoCopy.framingPreviewLabel)
        .accessibilityHint(ChildPhotoCopy.framingHint)
    }

    private func cutout(side: CGFloat, diameter: CGFloat) -> some View {
        let inset = (side - diameter) / 2
        let circle = CGRect(x: inset, y: inset, width: diameter, height: diameter)
        return ZStack {
            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: side, height: side))
                path.addEllipse(in: circle)
            }
            .fill(Color.ink.opacity(0.58), style: FillStyle(eoFill: true))

            Circle()
                .strokeBorder(Color.canvas.opacity(0.9), lineWidth: 2)
                .frame(width: diameter, height: diameter)
        }
        .allowsHitTesting(false)
    }

    // MARK: Work

    /// Decode once, upright, at drawing size.
    ///
    /// `AvatarCrop.upright` is the same call `square(_:focus:)` makes, so the picture on screen and
    /// the picture the crop is taken from are the same orientation — which is the whole reason the
    /// normalised rectangle can be handed between them.
    /// **Off the main actor, so the cover's presentation animation is not what pays for the
    /// decode.** `AvatarCrop.upright` is `nonisolated` for this: it costs tens of milliseconds on a
    /// full-size photograph, and spending that on the main thread while a modal slides up is a
    /// visible stutter on the one screen whose job is to look at a picture. The screen opens on ink
    /// with the button disabled and the photo lands a frame or two later, which is the trade every
    /// photo editor makes.
    private func prepare() async {
        let data = request.data
        let pixels = Self.previewPixels
        let decoded = await Task.detached(priority: .userInitiated) {
            try? AvatarCrop.upright(data, maxPixels: pixels)
        }.value

        guard let decoded else {
            // All three of `AvatarCrop`'s failures are the same fact to a parent: this picture will
            // not do. Said in the line under the hint rather than as an alert, and the confirming
            // button stays disabled so there is nothing to press that would do nothing.
            imageSize = nil
            unreadable = true
            return
        }
        imageSize = CGSize(width: decoded.width, height: decoded.height)
        #if canImport(UIKit)
        preview = UIImage(cgImage: decoded)
        #endif
        unreadable = false
    }

    /// **The geometry is rebuilt at the viewport that drew it, not at an arbitrary one.**
    /// Normalising is what makes the *result* independent of the viewport; the inputs are not —
    /// `offset` is in points, measured against the square the parent actually dragged in, so a
    /// geometry built at any other size would read those points as a different fraction of the
    /// picture. `drawnViewport` is recorded by the `GeometryReader` for exactly this.
    private func use() {
        // Positive dimensions, not merely non-nil: `focus`'s degenerate branch returns a rectangle
        // that is not square in pixels, and the one thing this must never do is hand that to the
        // crop and write a top-left corner of somebody's photograph onto their child's name.
        guard let imageSize, imageSize.width > 0, imageSize.height > 0, drawnViewport > 0 else { return }
        let geometry = AvatarFramingGeometry(imageSize: imageSize, viewport: drawnViewport)
        do {
            onUse(try AvatarCrop.square(request.data, focus: geometry.focus(offset: offset, scale: scale)))
        } catch {
            unreadable = true
        }
    }
}

#if canImport(UIKit)
/// The picture, transformed exactly the way `AvatarFramingGeometry` models it.
///
/// **Extracted so the correspondence can be tested rather than assumed.** The geometry decides
/// where the crop rectangle goes; this decides what the parent sees; and the whole feature is a lie
/// if the two disagree by so much as a scale factor. `AvatarFramingPictureTests` renders this at a
/// known offset and compares the pixel under the circle against the pixel `AvatarCrop` returns for
/// the same offset — which is the only assertion that says *what you see is what you get*.
///
/// `scaledToFill` into a `side × side` frame is `baseScale`; `scaleEffect` about the centre is
/// `scale`; `offset` is the translation. Change one of the three and the geometry has to change
/// with it.
struct AvatarFramingPicture: View {
    let image: UIImage?
    let geometry: AvatarFramingGeometry
    let offset: CGSize
    let scale: CGFloat

    var body: some View {
        ZStack {
            Color.ink
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.viewport, height: geometry.viewport)
                    .scaleEffect(scale)
                    .offset(offset)
            }
        }
        .frame(width: geometry.viewport, height: geometry.viewport)
        .clipped()
    }
}
#endif
