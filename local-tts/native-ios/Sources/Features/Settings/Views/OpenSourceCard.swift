import SwiftUI

/// Promo-style card on Settings, below the About row — unlike the flat
/// `appSecondaryBackground` list rows above it, this is deliberately built
/// as a translucent "liquid glass" card to stand out. Real Liquid Glass
/// (`.glassEffect()`) is iOS 26+ only; this app's deployment target is iOS
/// 17, so the same frosted look is built from `.ultraThinMaterial` + a
/// subtle stroke border instead — visually equivalent, works back to 17.
struct OpenSourceCard: View {
    private static let githubURL = URL(string: "https://github.com/Abusayid693/voice-app-ios")!
    private static let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

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
                        Image(systemName: "checkmark")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.appPrimaryText)
                        Text(point)
                            .font(.subheadline)
                            .foregroundStyle(Color.appSecondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                }
                contributeButton
                    .padding(.top, 4)
            }
            .padding(16)
            // Opaque, and the exact same color the header's scrim fades
            // into below — matching colors on both sides of that boundary
            // is what actually removes the seam, not just an approximate
            // gradient/material blend.
            .background(Color.appSecondaryBackground)
        }
        .background(.ultraThinMaterial, in: Self.cardShape)
        .overlay(Self.cardShape.strokeBorder(Color.white.opacity(0.12)))
        .clipShape(Self.cardShape)
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
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                Text("Built in the open, for everyone")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(16)
        }
        .frame(height: 160)
    }

    private var contributeButton: some View {
        Link(destination: Self.githubURL) {
            Text("Contribute")
                .font(.headline)
                .foregroundStyle(Color.appPrimaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
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
