import LucideSwift
import SwiftUI
import UIKit

/// A spine-out book using persisted dissolved artwork when available.
struct SavedProjectSpine: View {
    let coverURL: URL?
    let title: String
    let size: CGSize
    var cornerRadius: CGFloat = 3
    var showsTitle = true

    @State private var spineImage: UIImage?
    @State private var legacyCoverImage: UIImage?

    private var spineURL: URL? {
        coverURL?.deletingLastPathComponent().appendingPathComponent("spine.jpg")
    }

    var body: some View {
        ZStack {
            artwork

            spineShading

            if showsTitle {
                verticalTitle
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: coverURL) {
            spineImage = SavedProjectArtwork.loadImage(at: spineURL)
            legacyCoverImage = spineImage == nil
                ? SavedProjectArtwork.loadImage(at: coverURL)
                : nil
        }
        .accessibilityLabel("Spine for \(title)")
    }

    /// Legacy projects dissolve their cover at render time.
    private var artwork: some View {
        Group {
            if let image = spineImage ?? SavedProjectArtwork.cachedImage(at: spineURL) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let image = legacyCoverImage ?? SavedProjectArtwork.cachedImage(at: coverURL) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.18)
                    .blur(radius: 12)
            } else {
                LinearGradient.stablePlaceholder(seed: title)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// Darkened overall so white title text stays legible over whatever the
    /// artwork happens to be, plus a highlight/shadow pair along the two
    /// long edges for the rounded, catching-the-light look of a real spine.
    private var spineShading: some View {
        ZStack {
            Color.black.opacity(0.28)

            LinearGradient(
                colors: [
                    .white.opacity(0.28), .clear, .clear, .black.opacity(0.35),
                ],
                startPoint: .leading,
                endPoint: .trailing)
        }
        .allowsHitTesting(false)
    }

    /// Rotated bottom-to-top, the way English-language spines read when the
    /// book is standing up. Sized to the spine's *height* since that's the
    /// axis the text actually runs along after rotation.
    private var verticalTitle: some View {
        Text(title)
            .font(.system(size: min(size.width * 0.42, 11), weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(1)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
            .frame(width: max(0, size.height - 16))
            .rotationEffect(.degrees(-90))
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack(alignment: .bottom, spacing: 6) {
        SavedProjectSpine(
            coverURL: nil, title: "The Great Gatsby",
            size: CGSize(width: 18, height: 147))
        SavedProjectSpine(
            coverURL: nil, title: "Moby Dick, or The Whale",
            size: CGSize(width: 32, height: 147))
        SavedProjectSpine(
            coverURL: nil, title: "Short", size: CGSize(width: 14, height: 147))
    }
    .padding()
    .background(Color.whitePaper)
}
