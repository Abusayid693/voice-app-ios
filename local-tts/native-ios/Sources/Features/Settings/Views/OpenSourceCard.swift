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

    private static let points = [
        "Fully open source — read or change any line of it",
        "Runs on free, open-source TTS models",
        "Free forever: no ads, no subscriptions, nothing to unlock",
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
                    }
                }
                contributeButton
                    .padding(.top, 4)
            }
            .padding(16)
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
            // only near the bottom via a gradient mask, so the blur
            // strengthens gradually toward the edge instead of applying
            // uniformly everywhere.
            Image("SettingsCoverImage")
                .resizable()
                .scaledToFill()
                .frame(height: 160)
                .clipped()
                .blur(radius: 16)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom))

            // Darkening scrim for text legibility — reaches fully opaque
            // black right at the bottom edge (not just 0.8) so none of the
            // light source photo bleeds through into a visible seam where
            // the header meets the card's darker body below.
            LinearGradient(
                colors: [.clear, .black.opacity(0.5), .black],
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
