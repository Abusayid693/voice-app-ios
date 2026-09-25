import SwiftUI

/// A book on the shelf drawn as the two faces you can actually see — its
/// cover and its spine — turned about their shared vertical edge and
/// projected through **one shared camera**.
///
/// ## Why not `rotation3DEffect`
///
/// The obvious build (a `rotation3DEffect` on each face) looks like two
/// hinged cards, not a book. `perspective:` there is normalised to *each
/// view's own bounds*, so a 90pt cover and a 26pt spine get different
/// vanishing points and different foreshortening rates. They meet at the
/// hinge in 2D but never agree as one solid object.
///
/// Each face is planar, and the perspective projection of a plane is
/// exactly a 2D homography — which is what `ProjectionTransform` is. So
/// `BookFaceProjection` below computes the real projection from one camera
/// shared by both faces, and the corner reads as a corner.
///
/// ## Geometry
///
/// World space: `x` right, `y` down, `z` **toward the viewer**. The hinge is
/// the cover's leading edge at `x = 0`; the body extends back to `z = -S`.
/// Rotating by `angle` sends the cover's far edge backwards, which brings
/// the spine (the left face, normal `-X`) around to face front.
///
/// Note the spine sweeps to the *left* of the hinge as it comes round — so
/// the whole assembly is translated right by `S·sin θ`, which lands the
/// finished spine exactly in the `S`-wide slot the shelf commits to. Without
/// that it would settle a spine's width off to the left.
///
/// The page block (fore edge) is deliberately not modelled: this rotation
/// maps its normal `+X → -Z`, so it faces away for the entire turn and is
/// never visible.
struct RotatingBookFaces: View {
    let coverURL: URL?
    let title: String
    let coverSize: CGSize
    let spineWidth: CGFloat
    /// 0 = cover face-on, 90 = spine face-on.
    let angle: Double

    /// Distance from the eye to the `z = 0` plane, in points. Larger is a
    /// longer lens (flatter); this is ~6× the cover width, which gives
    /// visible foreshortening without the fish-eye a short lens produces at
    /// this size.
    private var eyeDistance: CGFloat { coverSize.width * 6 }

    private var radians: Double { angle * .pi / 180 }
    /// How squarely each face meets the viewer, 0...1 — the z-component of
    /// its normal. Cover normal starts `+Z` and becomes `(sin θ, cos θ)`;
    /// spine normal starts `-X` and becomes `(-cos θ, sin θ)`.
    private var coverFacing: Double { max(cos(radians), 0) }
    private var spineFacing: Double { max(sin(radians), 0) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            face(isSpine: false, facing: coverFacing) {
                SavedProjectCover(coverURL: coverURL, title: title, size: coverSize)
            }

            face(isSpine: true, facing: spineFacing) {
                SavedProjectSpine(
                    coverURL: coverURL, title: title,
                    size: CGSize(width: spineWidth, height: coverSize.height))
            }
        }
        // The lit corner where the two faces meet. Strongest mid-turn, when
        // the corner is actually pointing at you, and gone at either end
        // where there is no visible corner to catch light.
        .overlay(alignment: .bottomLeading) { hingeHighlight }
    }

    private func face<Content: View>(
        isSpine: Bool, facing: Double, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay(shading(facing: facing))
            // A face edge-on has no area to draw; fading the last sliver
            // also stops a spring overshoot flashing its back.
            .opacity(facing < 0.02 ? 0 : 1)
            .modifier(
                BookFaceProjection(
                    angle: angle,
                    coverWidth: coverSize.width,
                    spineWidth: spineWidth,
                    eyeDistance: eyeDistance,
                    isSpine: isSpine))
    }

    /// Light falloff plus a specular band that sweeps across the face as it
    /// turns. The moving highlight is what reads as a surface catching light
    /// rather than an image being squashed.
    private func shading(facing: Double) -> some View {
        let turn = 1 - facing
        return ZStack {
            Color.black.opacity(0.55 * turn)

            LinearGradient(
                colors: [.clear, .white.opacity(0.22 * facing), .clear],
                startPoint: UnitPoint(x: facing - 0.35, y: 0.1),
                endPoint: UnitPoint(x: facing + 0.35, y: 0.9))
        }
        .allowsHitTesting(false)
    }

    private var hingeHighlight: some View {
        // Sits on the hinge, which the assembly's own `S·sin θ` shift moves.
        let corner = sin(radians) * cos(radians) * 2  // peaks at 45°
        return Rectangle()
            .fill(.white.opacity(0.35 * corner))
            .frame(width: 1, height: coverSize.height)
            .offset(x: spineWidth * sin(radians))
            .allowsHitTesting(false)
    }
}

/// Projects one planar face of the book through the camera both faces share.
///
/// A face spans world `(x0, z0) → (x1, z1)` across its own local width, so
/// its depth is linear in local `x`, which makes the pinhole projection a
/// genuine 2D homography:
///
///     X = eyeX + (x - eyeX) · d / (d - z)
///     Y = eyeY + (y - eyeY) · d / (d - z)
///
/// Writing `D(t) = d - z(t)` (linear in local x) and clearing denominators
/// gives the matrix below directly. `animatableData` is the angle itself, so
/// the transform is rebuilt from a real angle every frame rather than
/// interpolated between two end matrices.
private struct BookFaceProjection: GeometryEffect {
    var angle: Double
    let coverWidth: CGFloat
    let spineWidth: CGFloat
    let eyeDistance: CGFloat
    let isSpine: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let theta = CGFloat(angle) * .pi / 180
        let cosT = cos(theta)
        let sinT = sin(theta)
        // Keeps the finished spine inside the slot the shelf commits to.
        let shift = spineWidth * sinT

        // The face's two vertical edges in world space, hinge at x = 0.
        let x0: CGFloat, x1: CGFloat, z0: CGFloat, z1: CGFloat
        if isSpine {
            // Local x = 0 is the spine's far edge so the artwork isn't
            // mirrored once it comes round to face the viewer.
            x0 = -spineWidth * sinT + shift
            z0 = -spineWidth * cosT
            x1 = shift
            z1 = 0
        } else {
            x0 = shift
            z0 = 0
            x1 = coverWidth * cosT + shift
            z1 = -coverWidth * sinT
        }

        let eyeX = coverWidth / 2
        let eyeY = size.height / 2
        let d = eyeDistance
        let depthAtOrigin = d - z0
        let depthSlope = -(z1 - z0)
        let inverseWidth = size.width > 0 ? 1 / size.width : 0

        var transform = ProjectionTransform()
        transform.m11 = inverseWidth * (eyeX * depthSlope + (x1 - x0) * d)
        transform.m21 = 0
        transform.m31 = eyeX * depthAtOrigin + (x0 - eyeX) * d
        transform.m12 = inverseWidth * eyeY * depthSlope
        transform.m22 = d
        transform.m32 = eyeY * (depthAtOrigin - d)
        transform.m13 = inverseWidth * depthSlope
        transform.m23 = 0
        transform.m33 = depthAtOrigin
        return transform
    }
}

#Preview {
    struct AnglePreview: View {
        @State private var angle: Double = 0

        var body: some View {
            VStack(spacing: 36) {
                HStack(alignment: .bottom, spacing: 34) {
                    ForEach([0.0, 25.0, 45.0, 70.0, 90.0], id: \.self) { fixed in
                        RotatingBookFaces(
                            coverURL: nil, title: "Moby Dick",
                            coverSize: CGSize(width: 90, height: 135),
                            spineWidth: 26, angle: fixed)
                        .frame(width: 90, height: 135, alignment: .bottomLeading)
                    }
                }

                RotatingBookFaces(
                    coverURL: nil, title: "Moby Dick",
                    coverSize: CGSize(width: 90, height: 135),
                    spineWidth: 26, angle: angle)
                .frame(width: 90, height: 135, alignment: .bottomLeading)

                Slider(value: $angle, in: 0...90)
                Button("Turn") {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        angle = angle > 45 ? 0 : 90
                    }
                }
            }
            .padding(40)
            .background(Color.whitePaper)
        }
    }
    return AnglePreview()
}
