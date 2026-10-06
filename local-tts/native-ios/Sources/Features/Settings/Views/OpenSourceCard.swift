import LucideSwift
import SwiftUI

/// Promo-style card on Settings, below the About row — unlike the flat
/// `appSecondaryBackground` list rows above it, this is deliberately built
/// as a translucent "liquid glass" card to stand out. Real Liquid Glass
/// (`.glassEffect()`) is iOS 26+ only; this app's deployment target is iOS
/// 17, so the same frosted look is built from `.ultraThinMaterial` + a
/// subtle stroke border instead — visually equivalent, works back to 17.
struct OpenSourceCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let githubURL = URL(string: "https://github.com/Abusayid693/voice-app-ios")!
    private static let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    // The inner content block (checkmarks + Contribute button) sits flush
    // against the header above it, so only its bottom corners carry the
    // card's own radius — its top stays explicitly square rather than
    // relying on being an unshaped seam under the header.
    private static let contentShape = UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: 24, bottomTrailingRadius: 24, topTrailingRadius: 0,
        style: .continuous)
    /// One full sweep, slow enough to read as ambient rather than a loading
    /// spinner — this card sits at rest on the page, not mid-task.
    private static let sweepPeriod: TimeInterval = 6

    // Short and parallel on purpose — each needs to fit on one line
    // without wrapping (see the `.lineLimit(1)` below).
    private static let points = [
        "Fully open source",
        "Free, open-source TTS models",
        "No ads, no subscriptions, no bullshit",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 10) {
                        LucideIcon(.check, size: 15, color: Color.appPrimaryText, strokeWidth: 3)
                        Text(point)
                            .appText(.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                }
                contributeButton
                    .padding(.top, 4)
            }
            .padding(16)
            .background(Color.appSecondaryBackground, in: Self.contentShape)
        }
        .background(.ultraThinMaterial, in: Self.cardShape)
        .clipShape(Self.cardShape)
        .overlay {
            // A dim base stroke keeps the card's edge visible even where the
            // bright sweep isn't currently passing, so the border never
            // disappears between passes.
            Self.cardShape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            rotatingBorder
        }
    }

    @ViewBuilder
    private var rotatingBorder: some View {
        if !reduceMotion {
            BorderSweep(shape: Self.cardShape, lineWidth: 1.5, period: Self.sweepPeriod)
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Image("SettingsCoverImage")
                .resizable()
                .scaledToFill()
                .frame(height: 160)
                .clipped()

            // Progressive blur: a blurred copy of the same image, revealed
            // increasingly toward the bottom via a gradient mask, so the
            // blur strengthens gradually approaching the edge instead of
            // applying uniformly everywhere or cutting off abruptly.
            Image("SettingsCoverImage")
                .resizable()
                .scaledToFill()
                .frame(height: 160)
                .clipped()
                .blur(radius: 20)
                .mask(
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom)
                )

            // Darkening scrim for text legibility, ending at the *exact*
            // same flat color as the content section below
            // (Color.appSecondaryBackground) rather than plain black — so
            // the header visually blends straight into the card body
            // instead of leaving a hard seam where a different tone would
            // otherwise meet it.
            LinearGradient(
                colors: [.clear, Color.appSecondaryBackground.opacity(0.6), Color.appSecondaryBackground],
                startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text("OPEN SOURCE")
                    .appHighlightLabel()
                    // Smaller than the shared badge default (labelStrong,
                    // 14pt) — this one badge only, via the next-smaller
                    // token in the scale rather than a literal size.
                    .font(AppTextStyle.meta.font)
                Text("Built in the open, for everyone")
                    .appText(.titleOnImage)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(16)
        }
        .frame(height: 160)
    }

    // A real Button (not Link) so .buttonStyle(.primary) can attach —
    // opens the URL via the environment action instead.
    private var contributeButton: some View {
        Button {
            openURL(Self.githubURL)
        } label: {
            Text("Contribute")
        }
        .buttonStyle(.primary)
    }
}

/// A bright arc travelling clockwise around the card's edge.
///
/// The gradient itself never changes and the mask never changes — only a
/// `rotationEffect` animates, which Core Animation runs on the render server.
/// Nothing here re-evaluates per frame.
///
/// That matters because the first version drove this from
/// `TimelineView(.animation)`, rebuilding the gradient and re-stroking the
/// shape every display refresh (120Hz on ProMotion) directly on top of a view
/// whose background is `.ultraThinMaterial` — so each tick re-blended the
/// material behind it, competing with scrolling for the same frame budget.
/// `PDFImportShelfCover`'s shimmer can afford `TimelineView` because its
/// `Canvas` is the only thing on that surface; this one sits over a material
/// card inside a scroll view, so it cannot.
private struct BorderSweep<S: InsettableShape>: View {
    let shape: S
    let lineWidth: CGFloat
    let period: Double

    @State private var angle: Double = 0

    var body: some View {
        GeometryReader { proxy in
            // Square, sized to the card's diagonal: a smaller one would leave
            // the corners uncovered as it turns.
            let side = hypot(proxy.size.width, proxy.size.height)
            AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.82),
                    .init(color: Color.white.opacity(0.9), location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                center: .center)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(angle))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .mask(shape.strokeBorder(Color.white, lineWidth: lineWidth))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            // Reset first: scrolling the card out and back fires this again,
            // and resuming from a stale angle would restart mid-sweep.
            angle = 0
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}

#Preview {
    ZStack {
        Color.appBackground.ignoresSafeArea()
        OpenSourceCard().padding()
    }
    .preferredColorScheme(.dark)
}
