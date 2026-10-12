import CoreText
import SwiftUI
import UIKit

/// Draws a shaped line of text as a left-to-right ink reveal. Core Text glyph
/// contours are cached by content and font, so animation frames only redraw the
/// small Canvas rather than reshaping text or invalidating the surrounding page.
struct SignatureText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var scaledFontSize: CGFloat = 36

    let text: String
    let isRevealed: Bool
    let color: Color
    let duration: TimeInterval
    let delay: TimeInterval
    let isHeading: Bool

    private let font: UIFont
    private let artwork: SignatureArtwork

    init(
        _ text: String,
        isRevealed: Bool,
        color: Color,
        fontName: String = AppEditorialFont.italicName,
        fontSize: CGFloat = 36,
        fontWeight: UIFont.Weight = .medium,
        duration: TimeInterval = 1.15,
        delay: TimeInterval = 0,
        isHeading: Bool = false
    ) {
        self.text = text
        self.isRevealed = isRevealed
        self.color = color
        self.duration = duration
        self.delay = delay
        self.isHeading = isHeading
        _scaledFontSize = ScaledMetric(wrappedValue: fontSize, relativeTo: .title)

        let base = UIFont(name: fontName, size: fontSize)
            ?? UIFont.italicSystemFont(ofSize: fontSize)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: fontWeight]
        ])
        let resolvedFont = UIFont(descriptor: descriptor, size: fontSize)
        font = resolvedFont
        artwork = SignatureArtworkCache.artwork(text: text, font: resolvedFont)
    }

    var body: some View {
        let content = Text(text)
            .font(Font(font.withSize(scaledFontSize)))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .hidden()
            .overlay {
                SignatureInk(
                    artwork: artwork,
                    color: color,
                    progress: reduceMotion || isRevealed ? 1 : 0)
                    .animation(
                        isRevealed && !reduceMotion
                            ? .linear(duration: duration).delay(delay)
                            : nil,
                        value: isRevealed)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)

        if isHeading {
            content.accessibilityAddTraits(.isHeader)
        } else {
            content
        }
    }
}

private struct SignatureArtwork {
    let glyphs: [Path]
    let bounds: CGRect

    init(text: String, font: UIFont) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        var paths: [Path] = []
        var bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: ascent + descent)

        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            for index in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], nil)
                else { continue }
                let path = Path(outline).applying(CGAffineTransform(
                    a: 1,
                    b: 0,
                    c: 0,
                    d: -1,
                    tx: positions[index].x,
                    ty: ascent - positions[index].y))
                paths.append(path)
                bounds = bounds.union(path.boundingRect)
            }
        }

        self.glyphs = paths
        self.bounds = bounds
    }
}

private final class SignatureArtworkBox: NSObject {
    let artwork: SignatureArtwork

    init(_ artwork: SignatureArtwork) {
        self.artwork = artwork
    }
}

private enum SignatureArtworkCache {
    private static let storage = NSCache<NSString, SignatureArtworkBox>()

    static func artwork(text: String, font: UIFont) -> SignatureArtwork {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let cached = storage.object(forKey: key) {
            return cached.artwork
        }

        let artwork = SignatureArtwork(text: text, font: font)
        storage.setObject(SignatureArtworkBox(artwork), forKey: key)
        return artwork
    }
}

/// Only this Canvas interpolates every frame; its parent page remains static.
private struct SignatureInk: View, Animatable {
    let artwork: SignatureArtwork
    let color: Color
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let bounds = artwork.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let transform = CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: scale,
                tx: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                ty: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)

            for (index, glyph) in artwork.glyphs.enumerated() {
                let start = Double(index) / Double(max(1, artwork.glyphs.count - 1)) * 0.68
                let drawn = min(1, max(0, (progress - start) / 0.32))
                guard drawn > 0 else { continue }
                let fillPhase = min(1, max(0, (drawn - 0.65) / 0.35))
                let fill = fillPhase * fillPhase * (3 - 2 * fillPhase)
                let path = glyph.applying(transform)

                context.stroke(
                    path.trimmedPath(from: 0, to: CGFloat(drawn)),
                    with: .color(color.opacity(1 - fill)),
                    style: StrokeStyle(
                        lineWidth: 0.75 * scale,
                        lineCap: .round,
                        lineJoin: .round))
                context.fill(path, with: .color(color.opacity(fill)))
            }
        }
    }
}
