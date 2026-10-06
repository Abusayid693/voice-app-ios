import SwiftUI
import UIKit

/// A textured spine derived from the cover palette with one horizontal title word.
struct SavedProjectSpine: View {
    let coverURL: URL?
    let artworkURL: URL?
    let title: String
    let size: CGSize
    var cornerRadius: CGFloat = 3

    @State private var coverImage: UIImage?
    @State private var rasterizedArtwork: UIImage?

    var body: some View {
        Group {
            if let rasterizedArtwork
                = rasterizedArtwork ?? SavedProjectArtwork.cachedImage(at: artworkURL)
            {
                Image(uiImage: rasterizedArtwork)
                    .resizable()
                    .scaledToFill()
            } else {
                SavedProjectSpineArtworkView(
                    coverImage: coverImage ?? SavedProjectArtwork.cachedImage(at: coverURL),
                    title: title,
                    size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.14), lineWidth: 0.5)
        }
        .task(id: artworkTaskID) {
            await loadArtwork()
        }
        .accessibilityLabel("Spine for \(title)")
    }

    private var artworkTaskID: String {
        "\(coverURL?.path ?? "fallback")|\(artworkURL?.path ?? "live")|\(title)|\(size.width)"
    }

    @MainActor
    private func loadArtwork() async {
        if let artwork = SavedProjectArtwork.loadImage(at: artworkURL) {
            rasterizedArtwork = artwork
            coverImage = nil
        } else {
            rasterizedArtwork = nil
            coverImage = SavedProjectArtwork.loadImage(at: coverURL)
        }
    }

    private var resolvedCornerRadius: CGFloat {
        min(cornerRadius, max(1, size.width * 0.22))
    }
}

private struct SavedProjectSpineArtworkView: View {
    let coverImage: UIImage?
    let title: String
    let size: CGSize

    var body: some View {
        ZStack {
            artwork
            decorativeType
            clothTexture
            spineShading
            edgeDetail
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var artwork: some View {
        Group {
            if let image = coverImage {
                ZStack {
                    coverLayer(image)
                        .scaleEffect(1.12)
                        .blur(radius: 5, opaque: true)
                        .saturation(1.18)
                        .contrast(1.12)

                    coverLayer(image)
                        .saturation(0.72)
                        .contrast(1.08)
                        .opacity(0.48)
                        .blendMode(.softLight)
                }
            } else {
                LinearGradient.stablePlaceholder(seed: title)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func coverLayer(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height, alignment: cropAlignment)
    }

    private var decorativeType: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Text(decorationToken(at: index))
                        .font(.system(
                            size: decorationFontSize(at: index),
                            weight: index == 1 ? .medium : .regular,
                            design: .serif))
                        .tracking(index == 2 ? 1.2 : 0.2)
                        .foregroundStyle(
                            index.isMultiple(of: 2)
                                ? .white.opacity(0.38)
                                : .black.opacity(0.26))
                        .blendMode(.softLight)
                        .lineLimit(1)
                        .fixedSize()
                        .position(
                            x: decorationX(at: index, width: geometry.size.width),
                            y: decorationY(at: index, height: geometry.size.height))
                }

                Text(decorationWord)
                    .font(.system(size: decorationWordSize, weight: .medium, design: .serif))
                    .tracking(1.1)
                    .textCase(.uppercase)
                    .foregroundStyle(decorationWordColor)
                    .lineLimit(1)
                    .fixedSize()
                    .shadow(color: decorationWordShadow, radius: 0.6, y: 0.5)
                    .position(
                        x: decorationWordX(width: geometry.size.width),
                        y: decorationWordY(height: geometry.size.height))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var clothTexture: some View {
        Canvas { context, canvasSize in
            var y: CGFloat = 0
            while y < canvasSize.height {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: canvasSize.width, y: y))
                context.stroke(
                    line,
                    with: .color(.white.opacity(0.20)),
                    lineWidth: 0.5)
                y += 2
            }

            var x: CGFloat = 0
            while x < canvasSize.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: canvasSize.height))
                context.stroke(
                    line,
                    with: .color(.black.opacity(0.14)),
                    lineWidth: 0.45)
                x += 2.5
            }

            var dotY: CGFloat = 1
            var row = 0
            while dotY < canvasSize.height {
                var dotX: CGFloat = row.isMultiple(of: 2) ? 1 : 2.5
                while dotX < canvasSize.width {
                    let dot = CGRect(x: dotX, y: dotY, width: 0.65, height: 0.65)
                    context.fill(Path(ellipseIn: dot), with: .color(.black.opacity(0.18)))
                    dotX += 4
                }
                dotY += 4
                row += 1
            }
        }
        .blendMode(.overlay)
        .opacity(0.72)
        .allowsHitTesting(false)
    }

    private var spineShading: some View {
        ZStack {
            Color.black.opacity(0.04)

            LinearGradient(
                colors: [
                    .black.opacity(0.20),
                    .white.opacity(0.22),
                    .clear,
                    .black.opacity(0.30),
                ],
                startPoint: .leading,
                endPoint: .trailing)

            LinearGradient(
                colors: [.black.opacity(0.10), .clear, .clear, .black.opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private var edgeDetail: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.white.opacity(0.28))
                .frame(width: min(1, size.width * 0.12))
            Spacer(minLength: 0)
            Rectangle()
                .fill(.black.opacity(0.28))
                .frame(width: min(1, size.width * 0.12))
        }
        .allowsHitTesting(false)
    }

    private var cropAlignment: Alignment {
        switch decorationSeed % 3 {
        case 0: return .leading
        case 1: return .center
        default: return .trailing
        }
    }

    private var decorationSeed: Int {
        title.utf8.reduce(17) { ($0 &* 31 &+ Int($1)) & 0x7fff_ffff }
    }

    private func decorationToken(at index: Int) -> String {
        let tokens = ["A…", "W", "F", "M…", "N", "R", "S…", "E"]
        return tokens[(decorationSeed + index * 3) % tokens.count]
    }

    private func decorationFontSize(at index: Int) -> CGFloat {
        let variation = CGFloat((decorationSeed / (index + 1)) % 7)
        return min(max(15 + variation, size.width * 1.15), 34)
    }

    private func decorationX(at index: Int, width: CGFloat) -> CGFloat {
        let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
        return width / 2 + direction * min(width * 0.18, 5)
    }

    private func decorationY(at index: Int, height: CGFloat) -> CGFloat {
        let base = [0.24, 0.53, 0.81][index]
        let jitter = Double((decorationSeed >> (index * 3)) & 0x7) / 100
        return height * CGFloat(min(base + jitter, 0.9))
    }

    private var decorationWord: String {
        let words = title
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        let ignoredWords: Set<String> = [
            "a", "an", "and", "by", "for", "in", "of", "on", "the", "to",
        ]
        let meaningfulWords = words.filter { !ignoredWords.contains($0.lowercased()) }
        return meaningfulWords.max(by: { $0.count < $1.count })
            ?? words.first
            ?? "Book"
    }

    private var decorationWordSize: CGFloat {
        min(max(size.width * 0.62, 9), 15)
    }

    private var decorationWordColor: Color {
        decorationSeed.isMultiple(of: 2)
            ? .white.opacity(0.72)
            : .black.opacity(0.62)
    }

    private var decorationWordShadow: Color {
        decorationSeed.isMultiple(of: 2)
            ? .black.opacity(0.28)
            : .white.opacity(0.24)
    }

    private func decorationWordX(width: CGFloat) -> CGFloat {
        let offsetSteps = CGFloat((decorationSeed / 7) % 5) - 2
        return width / 2 + offsetSteps * min(width * 0.12, 2.5)
    }

    private func decorationWordY(height: CGFloat) -> CGFloat {
        let positions: [CGFloat] = [0.38, 0.48, 0.59, 0.69]
        return height * positions[(decorationSeed / 13) % positions.count]
    }

}

/// Produces the shelf bitmap; import services own when and where it is stored.
@MainActor
enum SavedProjectSpineRenderer {
    nonisolated static let shelfHeight: CGFloat = 96

    static func pngData(coverData: Data, title: String, size: CGSize) -> Data? {
        guard size.width > 0, size.height > 0,
              let coverImage = UIImage(data: coverData)
        else { return nil }

        let content = SavedProjectSpineArtworkView(
            coverImage: coverImage,
            title: title,
            size: size)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage?.pngData()
    }
}

#Preview {
    HStack(alignment: .bottom, spacing: 6) {
        SavedProjectSpine(
            coverURL: nil, artworkURL: nil, title: "The Great Gatsby",
            size: CGSize(width: 18, height: 147))
        SavedProjectSpine(
            coverURL: nil, artworkURL: nil, title: "Moby Dick, or The Whale",
            size: CGSize(width: 32, height: 147))
        SavedProjectSpine(
            coverURL: nil, artworkURL: nil, title: "Short",
            size: CGSize(width: 14, height: 147))
    }
    .padding()
    .background(Color.whitePaper)
}
