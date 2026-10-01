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
            if let image = image ?? SavedProjectArtwork.cachedImage(at: coverURL) {
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
            image = SavedProjectArtwork.loadImage(at: coverURL)
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

/// Shares decoded artwork across shelf, spine, and hero views without a placeholder on handoff.
@MainActor
enum SavedProjectArtwork {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    static func cachedImage(at url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    static func loadImage(at url: URL?) -> UIImage? {
        guard let url else { return nil }
        if let image = cachedImage(at: url) { return image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        store(image, at: url)
        return image
    }

    static func store(_ image: UIImage, at url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}
