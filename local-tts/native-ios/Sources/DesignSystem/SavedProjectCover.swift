import LucideSwift
import SwiftUI
import UIKit

/// A persisted PDF cover at any presentation size. Both the compact project
/// row and the Book Shelf load the same local `cover.jpg`; a generated cover
/// keeps an imported book recognizable if that optional JPEG is unavailable.
struct SavedProjectCover: View {
    let coverURL: URL?
    let title: String
    let size: CGSize
    var cornerRadius: CGFloat = 3

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackCover
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: coverURL) {
            image = coverURL.flatMap { UIImage(contentsOfFile: $0.path) }
        }
        .accessibilityLabel("Cover for \(title)")
    }

    private var fallbackCover: some View {
        LinearGradient.stablePlaceholder(seed: title)
            .overlay {
                LucideIcon(.book, style: .filled, size: min(size.width, size.height) * 0.26,
                           color: .white.opacity(0.9))
            }
    }
}
