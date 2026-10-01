import LucideSwift
import SwiftUI
import UIKit

/// A book turned spine-out on the Book Shelf — the same persisted
/// `cover.jpg` `SavedProjectCover` draws, center-cropped to a narrow strip,
/// with the title running vertically over it when the book is thick enough.
///
/// `scaledToFill` inside a spine-width frame is what does the cropping: the
/// image keeps its aspect ratio and overflows horizontally, so what's left
/// is the middle slice of the artwork rather than a squashed whole cover.
/// The two edge gradients are what make that strip read as a *spine* and not
/// just a clipped cover — a real one catches light along its hinge and falls
/// into shadow at the fore edge.
struct SavedProjectSpine: View {
    let coverURL: URL?
    let title: String
    let size: CGSize
    var cornerRadius: CGFloat = 3
    var showsTitle = true

    @State private var image: UIImage?

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
            image = SavedProjectArtwork.loadImage(at: coverURL)
        }
        .accessibilityLabel("Spine for \(title)")
    }

    /// The cover turned on its side and run down the spine, so the artwork
    /// follows the spine's long axis instead of being cropped to a thin
    /// upright sliver of itself.
    ///
    /// The frame is deliberately **swapped** (`height × width`) *before*
    /// rotating: `rotationEffect` doesn't change layout, so filling the
    /// rotated shape means filling the pre-rotation rectangle it came from.
    /// The outer frame afterwards reclaims the spine's real footprint. Same
    /// -90° as `verticalTitle`, so artwork and title run the same way.
    private var artwork: some View {
        Group {
            if let image = image ?? SavedProjectArtwork.cachedImage(at: coverURL) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient.stablePlaceholder(seed: title)
            }
        }
        .frame(width: size.height, height: size.width)
        .clipped()
        .rotationEffect(.degrees(-90))
        .frame(width: size.width, height: size.height)
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
