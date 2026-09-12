import SwiftUI

/// An organic, rounded "blob" — a circle whose radius is perturbed by a
/// couple of sine harmonics around its circumference, sampled densely
/// enough (120 points, straight segments between them) that the result
/// reads as one smooth, softly-lumpy silhouette with no visible per-vertex
/// corners — in the style of a soft, audio-reactive orb.
///
/// Two animatable inputs, combined via `AnimatablePair` so SwiftUI can
/// interpolate both:
/// - `amplitude` (0...1): how strongly the radius is perturbed. `0` is a
///   perfect circle regardless of `phase` — meant to track a live audio
///   level, so the shape is dead calm at rest and only deforms while
///   something is actually playing.
/// - `phase`: a continuously-advancing radians offset that travels the
///   lobes around the shape over time, so a held amplitude still looks
///   alive rather than a static bumpy circle. Meant to be driven every
///   frame from a `TimelineView(.animation)` (computed directly from
///   elapsed time), not from a discrete animated state change — the
///   perturbation is already continuous by construction, so there's
///   nothing to interpolate *between*.
struct BlobShape: Shape {
    var amplitude: CGFloat
    var phase: CGFloat
    /// Number of harmonic bulges — more = smaller, more frequent lobes.
    var lobes: Int = 4

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(amplitude, phase) }
        set {
            amplitude = newValue.first
            phase = newValue.second
        }
    }

    // Both harmonics are weighted 0.6 + 0.4, so their sum is bounded to
    // ±1.0 — combined with the 0.18 wobble scale below, the radius can grow
    // at most 18% past baseRadius at amplitude 1. wobbleScale is baked into
    // this constant too so the two can't drift out of sync.
    private static let wobbleScale: CGFloat = 0.12
    private static let maxWobbleMagnitude: CGFloat = 1.0

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Shrunk so the largest possible bulge (amplitude 1, max wobble)
        // still lands exactly at the view's own edge instead of past it —
        // otherwise outward bulges get flatly clipped by the view's frame,
        // which reads as a hard, straight cut rather than a smooth curve.
        let baseRadius = (min(rect.width, rect.height) / 2)
            / (1 + Self.wobbleScale * Self.maxWobbleMagnitude)
        let sampleCount = 120

        var points: [CGPoint] = []
        points.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let theta = (CGFloat(i) / CGFloat(sampleCount)) * 2 * .pi
            // Two harmonics at different frequencies/phase-offsets so the
            // lobes aren't perfectly symmetric — reads as organic, not a
            // gear or a flower.
            let wobble =
                sin(CGFloat(lobes) * theta + phase) * 0.6
                + sin(CGFloat(lobes - 2) * theta - phase * 1.3) * 0.4
            let radius = baseRadius * (1 + amplitude * Self.wobbleScale * wobble)
            points.append(
                CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta)))
        }

        // Smooths the sampled polygon into a continuous curve by drawing a
        // quadratic curve through the midpoint of each edge, using the
        // sampled vertex as the control point — a standard closed-blob
        // smoothing trick. Straight lines between samples (the previous
        // approach) left visible corners at sharper bulge peaks; this
        // removes them entirely rather than just sampling more densely.
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }

        var path = Path()
        path.move(to: midpoint(points[points.count - 1], points[0]))
        for i in points.indices {
            let next = points[(i + 1) % points.count]
            path.addQuadCurve(to: midpoint(points[i], next), control: points[i])
        }
        path.closeSubpath()
        return path
    }
}
