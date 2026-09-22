import PDFKit
import UIKit

/// Small seam around extraction. PDFKit is the v1 implementation, but the
/// import pipeline only consumes these app-owned line values, so
/// a commercial extractor can replace it later without changing jobs or UI.
protocol PDFTextExtractor {
    func extractPage(_ page: PDFPage, index: Int) -> PDFPageContent
}

struct PDFKitTextExtractor: PDFTextExtractor {
    func extractPage(_ page: PDFPage, index: Int) -> PDFPageContent {
        autoreleasepool {
            let cropBox = page.bounds(for: .cropBox)
            let visualSize = visualPageSize(cropBox: cropBox, rotation: page.rotation)
            guard let selection = page.selection(for: cropBox) else {
                return PDFPageContent(
                    pageIndex: index, pageWidth: visualSize.width, pageHeight: visualSize.height, lines: [])
            }

            let lines = selection.selectionsByLine().compactMap { lineSelection -> PDFTextFragment? in
                guard let text = normalizedText(lineSelection.string), !text.isEmpty else { return nil }
                let lineBounds = lineSelection.bounds(for: page)
                guard !lineBounds.isNull, !lineBounds.isEmpty else { return nil }
                let typography = attributes(for: lineSelection.attributedString)
                return PDFTextFragment(
                    text: text, pageIndex: index,
                    bounds: normalizedBounds(lineBounds, cropBox: cropBox, rotation: page.rotation),
                    fontName: typography.name, fontSize: typography.size, isBold: typography.isBold)
            }

            return PDFPageContent(
                pageIndex: index, pageWidth: visualSize.width, pageHeight: visualSize.height,
                lines: order(lines: lines, pageWidth: visualSize.width))
        }
    }

    private func attributes(for attributedText: NSAttributedString?) -> (
        name: String?, size: Double, isBold: Bool
    ) {
        guard let attributedText, attributedText.length > 0 else {
            return (nil, 0, false)
        }
        let font = attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        return (
            font?.fontName, Double(font?.pointSize ?? 0),
            font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    private func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Converts lower-left PDF page coordinates into visual, top-left
    /// coordinates and applies the page's rotation before layout analysis.
    private func normalizedBounds(_ bounds: CGRect, cropBox: CGRect, rotation: Int) -> PDFNormalizedRect {
        let local = bounds.offsetBy(dx: -cropBox.minX, dy: -cropBox.minY)
        let width = cropBox.width
        let height = cropBox.height
        let normalized: CGRect
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            normalized = CGRect(
                x: local.minY, y: local.minX, width: local.height, height: local.width)
        case 180:
            normalized = CGRect(
                x: width - local.maxX, y: local.minY, width: local.width, height: local.height)
        case 270:
            normalized = CGRect(
                x: height - local.maxY, y: width - local.maxX, width: local.height, height: local.width)
        default:
            normalized = CGRect(
                x: local.minX, y: height - local.maxY, width: local.width, height: local.height)
        }
        return PDFNormalizedRect(normalized)
    }

    private func visualPageSize(cropBox: CGRect, rotation: Int) -> CGSize {
        switch ((rotation % 360) + 360) % 360 {
        case 90, 270: return CGSize(width: cropBox.height, height: cropBox.width)
        default: return CGSize(width: cropBox.width, height: cropBox.height)
        }
    }

    /// PDF text operators are not a reading-order guarantee. This produces a
    /// stable, geometry-driven order for normal magazine/paper layouts:
    /// full-width lines become horizontal bands; each band is read by
    /// inferred column starts, then top-to-bottom within a column.
    private func order(lines: [PDFTextFragment], pageWidth: Double) -> [PDFTextFragment] {
        guard lines.count > 1 else { return lines }
        let fullWidthThreshold = pageWidth * 0.72
        let spanning = lines
            .filter { $0.bounds.width >= fullWidthThreshold }
            .sorted { $0.bounds.y < $1.bounds.y }
        let body = lines.filter { $0.bounds.width < fullWidthThreshold }
        guard !spanning.isEmpty, !body.isEmpty else { return orderColumns(body.isEmpty ? lines : body, pageWidth: pageWidth) }

        var result: [PDFTextFragment] = []
        var bandStart = -Double.greatestFiniteMagnitude
        for line in spanning {
            let before = body.filter { $0.bounds.y >= bandStart && $0.bounds.y < line.bounds.y }
            result.append(contentsOf: orderColumns(before, pageWidth: pageWidth))
            result.append(line)
            bandStart = line.bounds.maxY
        }
        let after = body.filter { $0.bounds.y >= bandStart }
        result.append(contentsOf: orderColumns(after, pageWidth: pageWidth))
        return result
    }

    private func orderColumns(_ lines: [PDFTextFragment], pageWidth: Double) -> [PDFTextFragment] {
        guard lines.count > 1 else { return lines }
        let rightToLeft = isPredominantlyRightToLeft(lines)
        let startGap = max(36, pageWidth * 0.12)
        let starts = lines.map { $0.bounds.x }.sorted()
        var clusters: [[Double]] = []
        for start in starts {
            if let last = clusters.indices.last,
                start - (clusters[last].last ?? start) <= startGap
            {
                clusters[last].append(start)
            } else {
                clusters.append([start])
            }
        }

        // A single text column or noisy indentation: normal row ordering is
        // more reliable than treating each indentation as a new column.
        guard clusters.count > 1 else {
            return lines.sorted { lhs, rhs in
                abs(lhs.bounds.y - rhs.bounds.y) > 2
                    ? lhs.bounds.y < rhs.bounds.y
                    : rightToLeft ? lhs.bounds.x > rhs.bounds.x : lhs.bounds.x < rhs.bounds.x
            }
        }

        let centers = clusters.map { values in values.reduce(0, +) / Double(values.count) }
        var columns = Array(repeating: [PDFTextFragment](), count: centers.count)
        for line in lines {
            let column = centers.indices.min(by: {
                abs(centers[$0] - line.bounds.x) < abs(centers[$1] - line.bounds.x)
            }) ?? 0
            columns[column].append(line)
        }
        let orderedColumns = rightToLeft ? columns.reversed() : columns
        return orderedColumns.flatMap { column in
            column.sorted { lhs, rhs in
                abs(lhs.bounds.y - rhs.bounds.y) > 2
                    ? lhs.bounds.y < rhs.bounds.y
                    : rightToLeft ? lhs.bounds.x > rhs.bounds.x : lhs.bounds.x < rhs.bounds.x
            }
        }
    }

    private func isPredominantlyRightToLeft(_ lines: [PDFTextFragment]) -> Bool {
        var rightToLeftScalars = 0
        var letterScalars = 0
        for scalar in lines.flatMap({ $0.text.unicodeScalars }) {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                rightToLeftScalars += 1
                letterScalars += 1
            default:
                if CharacterSet.letters.contains(scalar) { letterScalars += 1 }
            }
        }
        return letterScalars > 0 && Double(rightToLeftScalars) / Double(letterScalars) > 0.5
    }
}
