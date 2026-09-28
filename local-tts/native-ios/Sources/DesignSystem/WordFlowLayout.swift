import SwiftUI

/// Flows its children left-to-right, top-to-bottom, wrapping like text —
/// for a paragraph built from individual per-word views (each independently
/// styleable, e.g. a highlighted background behind just one word) rather
/// than a single `Text`. Plain `Text` concatenation (`Text + Text + ...`)
/// can't give one piece within the run its own background, which is
/// exactly what per-word highlight requires — see `ChapterPlayerView
/// .paragraphText`, the only consumer today.
///
/// A child forces a new line before itself via `.lineBreaksBefore(_:)` —
/// 0 for normal flow, 1 for a single line break, 2+ for a paragraph break
/// (extra vertical gap on top of the line break itself). This is how real
/// newlines inside a chunk's own text (preserved via `WordTiming
/// .precedingSeparator`) still render as real breaks even though each word
/// is now its own view instead of one `Text` with literal `"\n"` in it.
struct WordFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 6
    // Extra vertical gap added on top of verticalSpacing for a 2+ break
    // (paragraph break), so it reads as more separated than a plain
    // single-newline line break.
    var paragraphExtraSpacing: CGFloat = 8
    // Bump this whenever anything that affects a child's MEASURED size
    // changes — its text, or the font it's rendered in. Sizes are then
    // re-measured only when it moves, instead of on every layout pass:
    // the caller re-runs its body ~12x/sec while highlighting (only the
    // highlighted word's colors change, which can't affect measurement),
    // and each of those passes was costing a Core Text measurement for
    // every word in the paragraph. Callers with a single fixed font and
    // fixed text can leave it at 0.
    var measurementVersion: Int = 0

    /// Optional: when set, each child's placed frame is recorded here, keyed
    /// by subview index — how `ChapterPlayerView` resolves a tap point to a
    /// specific word without attaching a gesture to every one of them, which
    /// would fight the row's own tap gesture and the ScrollView's drag.
    /// A reference type so writing to it during layout doesn't invalidate
    /// the view the way reassigning a `@State` value would — the same idiom
    /// as `ChapterPlayerView`'s `groupHeightsBox`/`visibleParagraphsBox`.
    final class FrameBox {
        var frames: [Int: CGRect] = [:]
    }
    var frameBox: FrameBox?

    // Measured sizes, so the two passes below don't each independently
    // call `sizeThatFits(.unspecified)` on every subview — that was
    // measuring every word twice per layout pass. How much this saves
    // beyond that 2x depends on how often SwiftUI calls `updateCache`,
    // which isn't a documented guarantee; treat the halving as the floor,
    // not the ceiling.
    //
    // Caching sizes at all is only safe because a word's text and padding
    // are constant regardless of highlight state (the reflow-avoidance
    // rule from when per-word highlight was added) — only the background
    // fill changes, which can't affect measurement.
    struct Cache {
        var sizes: [CGSize] = []
        var version: Int?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, version: measurementVersion)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // The count check isn't redundant with the version: a caller that
        // leaves measurementVersion at its default still needs its cache
        // refreshed when children are added or removed.
        guard cache.version != measurementVersion || cache.sizes.count != subviews.count else { return }
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.version = measurementVersion
    }

    // Never index `cache.sizes` directly: subview counts genuinely change
    // at runtime here (a paragraph's word count shifts when a streaming
    // chunk's real timings replace the plain-text fallback), and relying on
    // `updateCache` always landing before the next layout pass would make
    // a stale cache an index-out-of-range crash rather than a glitch.
    private func size(at index: Int, subview: LayoutSubview, cache: Cache) -> CGSize {
        index < cache.sizes.count ? cache.sizes[index] : subview.sizeThatFits(.unspecified)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var isFirstInLine = true
        for (index, subview) in subviews.enumerated() {
            let size = size(at: index, subview: subview, cache: cache)
            let breaks = subview[LineBreaksBeforeKey.self]
            if !isFirstInLine, breaks > 0 || lineWidth + size.width > maxWidth {
                totalHeight += lineHeight + lineGap(breaks: breaks, lineHeight: lineHeight)
                lineWidth = 0
                lineHeight = 0
                isFirstInLine = true
            } else if isFirstInLine, breaks >= 2, index > 0 {
                totalHeight += paragraphGap(lineHeight: size.height)
            }
            lineWidth += (isFirstInLine ? 0 : horizontalSpacing) + size.width
            lineHeight = max(lineHeight, size.height)
            isFirstInLine = false
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : lineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        var isFirstInLine = true
        frameBox?.frames.removeAll(keepingCapacity: true)
        for (index, subview) in subviews.enumerated() {
            let size = size(at: index, subview: subview, cache: cache)
            let breaks = subview[LineBreaksBeforeKey.self]
            if !isFirstInLine, breaks > 0 || x + size.width > bounds.minX + bounds.width {
                x = bounds.minX
                y += lineHeight + lineGap(breaks: breaks, lineHeight: lineHeight)
                lineHeight = 0
                isFirstInLine = true
            } else if isFirstInLine, breaks >= 2, index > 0 {
                // Must mirror sizeThatFits exactly, or the measured height and
                // the placement disagree and the last line clips.
                y += paragraphGap(lineHeight: size.height)
            }
            if !isFirstInLine { x += horizontalSpacing }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            // Relative to `bounds.minOrigin`, matching the coordinate space a
            // tap's `value.location` arrives in when the gesture is attached
            // to this same layout's frame.
            frameBox?.frames[index] = CGRect(
                x: x - bounds.minX, y: y - bounds.minY, width: size.width, height: size.height)
            x += size.width
            lineHeight = max(lineHeight, size.height)
            isFirstInLine = false
        }
    }

    private func lineGap(breaks: Int, lineHeight: CGFloat) -> CGFloat {
        breaks >= 2 ? verticalSpacing + paragraphGap(lineHeight: lineHeight) : verticalSpacing
    }

    /// A paragraph break is always worth at least one blank line, even when the
    /// source document set its paragraphs with no extra space at all (an
    /// indent-only book, for instance). `paragraphExtraSpacing` is a floor
    /// rather than the value, and the gap tracks the line height so it stays a
    /// blank line at every reader font size instead of a fixed few points.
    private func paragraphGap(lineHeight: CGFloat) -> CGFloat {
        max(paragraphExtraSpacing, lineHeight)
    }
}

private struct LineBreaksBeforeKey: LayoutValueKey {
    static let defaultValue = 0
}

extension View {
    func lineBreaksBefore(_ count: Int) -> some View {
        layoutValue(key: LineBreaksBeforeKey.self, value: count)
    }
}
