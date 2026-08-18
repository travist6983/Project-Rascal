import SwiftUI

/// The Vellum wordmark, drawn rather than set.
///
/// **Ported from `docs/app-icon/vellum-wordmark.svg` (phase 70), numbers unchanged.** The word is
/// drawn geometry rather than type, which is the property that makes this possible at all: there
/// is no font file to embed, no licence to honour, and nothing to go wrong between the design
/// tool and the app. It is one monoline stroke with round caps, so it scales to any size and
/// takes any tint without an asset pipeline — which also keeps rule 4 satisfied, since a vector
/// asset format would have meant either a dependency or a build step.
///
/// **The coordinates below are the SVG's, verbatim.** The source viewBox is `0 -126 531.5 126`,
/// i.e. y runs from -126 at the top to 0 at the bottom — already y-down, like SwiftUI — so the
/// only transform is a translation of +126 and a uniform scale. Keeping the numbers literal
/// means a redrawn wordmark can be re-pasted from the SVG rather than re-derived.
///
/// **The name is never set in capitals** — owner's rule, Aug 18, 2026, recorded in
/// `docs/design-system.md`. Where the name is a mark, this view. Where it is a word in a
/// sentence, sentence case. There is no third option, and `VELLUM` was the spelling a
/// case-sensitive rename could not find.
///
/// **Arcs are flattened to cubic Béziers here rather than handed to `addArc`.** SVG arcs are
/// endpoint-parameterised and `addArc` is centre-parameterised, and the `clockwise:` flag's
/// meaning depends on the coordinate system it is read in — which is exactly the kind of thing
/// that renders mirrored and passes every test. Converting explicitly removes the ambiguity.
struct Wordmark: Shape {

    /// The source viewBox. The path is inset from it by half the stroke width on every side, so
    /// stroking to this box is what makes the mark's optical bounds match its layout bounds.
    static let designSize = CGSize(width: 531.5, height: 126)
    /// `stroke-width` from the SVG, in design units.
    static let designStroke: CGFloat = 19.5

    /// The stroke width to draw this mark at, for a given rendered width.
    static func strokeWidth(forWidth width: CGFloat) -> CGFloat {
        designStroke * (width / designSize.width)
    }

    func path(in rect: CGRect) -> Path {
        // Uniform scale, so the mark never distorts if it is handed a box of the wrong ratio.
        let scale = min(rect.width / Self.designSize.width, rect.height / Self.designSize.height)
        let drawn = CGSize(
            width: Self.designSize.width * scale, height: Self.designSize.height * scale
        )
        let origin = CGPoint(
            x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2
        )

        // SVG y is negative-up-to-zero; +126 brings it to 0…126, then scale and offset.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + (y + Self.designSize.height) * scale)
        }

        var path = Path()

        // V
        path.move(to: p(9.75, -90.25))
        path.addLine(to: p(46, -9.75))
        path.addLine(to: p(82.25, -90.25))

        // e — the crossbar, then the bowl. The second arc is the large-arc case.
        path.move(to: p(106.949, -46))
        path.addLine(to: p(187.051, -46))
        path.addArc(to: p(147, -90.25), radius: 40.25, largeArc: false, sweep: false, scale: scale, origin: origin)
        path.addArc(to: p(176.912, -23.067), radius: 40.25, largeArc: true, sweep: false, scale: scale, origin: origin)

        // l, l
        path.move(to: p(214.75, -116.25))
        path.addLine(to: p(214.75, -9.75))
        path.move(to: p(249.25, -116.25))
        path.addLine(to: p(249.25, -9.75))

        // u
        path.move(to: p(283.75, -90.25))
        path.addLine(to: p(283.75, -47.5))
        path.addArc(to: p(359.25, -47.5), radius: 37.75, largeArc: false, sweep: false, scale: scale, origin: origin)
        path.move(to: p(359.25, -90.25))
        path.addLine(to: p(359.25, -9.75))

        // m — a stem and two shoulders.
        path.move(to: p(393.75, -9.75))
        path.addLine(to: p(393.75, -58.25))
        path.addArc(to: p(457.75, -58.25), radius: 32, largeArc: false, sweep: true, scale: scale, origin: origin)
        path.addLine(to: p(457.75, -9.75))
        path.move(to: p(457.75, -58.25))
        path.addArc(to: p(521.75, -58.25), radius: 32, largeArc: false, sweep: true, scale: scale, origin: origin)
        path.addLine(to: p(521.75, -9.75))

        return path
    }
}

extension Path {

    /// An SVG elliptical-arc command, as cubic Béziers.
    ///
    /// The W3C endpoint-to-centre conversion (SVG 1.1, F.6.5) followed by the standard
    /// quarter-arc Bézier approximation. Every arc in this wordmark is circular — `rx == ry` and
    /// no x-axis rotation — so the general ellipse case is deliberately not implemented rather
    /// than written and never exercised.
    fileprivate mutating func addArc(
        to end: CGPoint,
        radius: CGFloat,
        largeArc: Bool,
        sweep: Bool,
        scale: CGFloat,
        origin: CGPoint
    ) {
        let start = currentPoint ?? end
        let r = radius * scale
        guard r > 0, start != end else {
            addLine(to: end)
            return
        }

        // Midpoint in the primed frame. No rotation, so this is just the half-difference.
        let x1p = (start.x - end.x) / 2
        let y1p = (start.y - end.y) / 2

        // Grow the radius if it is too small to span the chord, which is what SVG requires
        // rather than failing. A wordmark that silently drops a letter is the worse outcome.
        var rr = r
        let lambda = (x1p * x1p + y1p * y1p) / (rr * rr)
        if lambda > 1 { rr *= lambda.squareRoot() }

        let num = max(0, rr * rr * rr * rr - rr * rr * (y1p * y1p + x1p * x1p))
        let den = rr * rr * (y1p * y1p + x1p * x1p)
        let coefficient = (den == 0 ? 0 : (num / den).squareRoot()) * (largeArc == sweep ? -1 : 1)

        let cxp = coefficient * (rr * y1p / rr)
        let cyp = coefficient * -(rr * x1p / rr)
        let center = CGPoint(
            x: cxp + (start.x + end.x) / 2,
            y: cyp + (start.y + end.y) / 2
        )

        var theta1 = atan2(start.y - center.y, start.x - center.x)
        let theta2 = atan2(end.y - center.y, end.x - center.x)
        var delta = theta2 - theta1
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // At most a quarter turn per Bézier: the approximation's error grows sharply past that.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)

        for _ in 0..<segments {
            let theta2Step = theta1 + step
            let p0 = CGPoint(
                x: center.x + rr * cos(theta1), y: center.y + rr * sin(theta1)
            )
            let p3 = CGPoint(
                x: center.x + rr * cos(theta2Step), y: center.y + rr * sin(theta2Step)
            )
            let c1 = CGPoint(
                x: p0.x - k * rr * sin(theta1), y: p0.y + k * rr * cos(theta1)
            )
            let c2 = CGPoint(
                x: p3.x + k * rr * sin(theta2Step), y: p3.y - k * rr * cos(theta2Step)
            )
            addCurve(to: p3, control1: c1, control2: c2)
            theta1 = theta2Step
        }
    }
}

/// The wordmark at a given width, stroked in ink.
///
/// A view rather than a raw `Shape` because the stroke width has to scale with the mark — a
/// fixed line weight would thicken the word as it got smaller, which is the one way a monoline
/// logo goes visibly wrong.
struct WordmarkView: View {
    var width: CGFloat = 104
    var tint: Color = .ink

    private var height: CGFloat {
        width * (Wordmark.designSize.height / Wordmark.designSize.width)
    }

    var body: some View {
        Wordmark()
            .stroke(
                tint,
                style: StrokeStyle(
                    lineWidth: Wordmark.strokeWidth(forWidth: width),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: width, height: height)
            .accessibilityLabel("Vellum")
    }
}

#if DEBUG
#Preview("Wordmark") {
    VStack(alignment: .leading, spacing: 28) {
        WordmarkView(width: 104)
        WordmarkView(width: 180)
        WordmarkView(width: 260)
        WordmarkView(width: 180, tint: .inkMuted)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.canvas)
}
#endif
