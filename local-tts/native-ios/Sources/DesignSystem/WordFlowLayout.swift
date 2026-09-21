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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var isFirstInLine = true
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let breaks = subview[LineBreaksBeforeKey.self]
            if !isFirstInLine, breaks > 0 || lineWidth + size.width > maxWidth {
                totalHeight += lineHeight + lineGap(breaks: breaks)
                lineWidth = 0
                lineHeight = 0
                isFirstInLine = true
            }
            lineWidth += (isFirstInLine ? 0 : horizontalSpacing) + size.width
            lineHeight = max(lineHeight, size.height)
            isFirstInLine = false
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : lineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        var isFirstInLine = true
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let breaks = subview[LineBreaksBeforeKey.self]
            if !isFirstInLine, breaks > 0 || x + size.width > bounds.minX + bounds.width {
                x = bounds.minX
                y += lineHeight + lineGap(breaks: breaks)
                lineHeight = 0
                isFirstInLine = true
            }
            if !isFirstInLine { x += horizontalSpacing }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
            isFirstInLine = false
        }
    }

    private func lineGap(breaks: Int) -> CGFloat {
        breaks >= 2 ? verticalSpacing + paragraphExtraSpacing : verticalSpacing
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
