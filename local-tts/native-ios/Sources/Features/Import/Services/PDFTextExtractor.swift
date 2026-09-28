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

    /// Reports the line's *dominant* font — the one covering the most
    /// characters — not whichever font the first glyph happens to use.
    ///
    /// Sampling run 0 (what this did before) misreported any line whose
    /// opening character came from a different font, which PDFs produce
    /// constantly: one visual typeface is routinely split across several
    /// subset fonts, and a leading quote mark or a bold run-in word is enough.
    /// Paragraph assembly compares sizes and weights between lines, so a
    /// misread first glyph used to split paragraphs at random.
    private func attributes(for attributedText: NSAttributedString?) -> (
        name: String?, size: Double, isBold: Bool
    ) {
        guard let attributedText, attributedText.length > 0 else {
            return (nil, 0, false)
        }
        var coverage: [Int: (font: UIFont, length: Int)] = [:]
        let whole = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let key = font.hashValue
            coverage[key, default: (font, 0)].length += range.length
        }
        guard let dominant = coverage.values.max(by: { $0.length < $1.length })?.font else {
            return (nil, 0, false)
        }
        return (dominant.fontName, Double(dominant.pointSize), isBold(dominant))
    }

    /// Many embedded PDF fonts never set `.traitBold`, so the descriptor alone
    /// misses real bold text; the name is the fallback signal.
    private func isBold(_ font: UIFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) { return true }
        let name = font.fontName.lowercased()
        return ["bold", "black", "heavy", "semibold"].contains { name.contains($0) }
    }

    /// Folds a line down to plain, single-spaced text.
    ///
    /// The reader itself never shows a run of spaces (it renders each word as
    /// its own view), but this string is also what the TTS engine speaks, what
    /// the page picker excerpts, and what the 500-character validity check
    /// counts — all of which want it clean. Zero-width characters in
    /// particular would otherwise ride along invisibly into the phonemizer.
    private func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        var value = ""
        value.reserveCapacity(text.count)
        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            switch scalar.value {
            case 0x0000, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
                continue  // NUL and zero-width joiners/spaces carry nothing.
            case 0x00AD:
                // A soft hyphen only means something at a wrap, where the
                // assembler's dehyphenation needs to see it as a hyphen.
                value.append("-")
            case 0x0009, 0x00A0, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
                value.append(" ")
            default:
                value.append(character)
            }
        }
        return Self.collapsed(Self.decomposingLigatures(in: value))
    }

    /// PDFKit passes ligature glyphs straight through, and the phonemizer has
    /// no idea what to do with "ﬁ".
    private static func decomposingLigatures(in text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) }) else {
            return text
        }
        return text
            .replacingOccurrences(of: "\u{FB00}", with: "ff")
            .replacingOccurrences(of: "\u{FB01}", with: "fi")
            .replacingOccurrences(of: "\u{FB02}", with: "fl")
            .replacingOccurrences(of: "\u{FB03}", with: "ffi")
            .replacingOccurrences(of: "\u{FB04}", with: "ffl")
            .replacingOccurrences(of: "\u{FB05}", with: "st")
            .replacingOccurrences(of: "\u{FB06}", with: "st")
    }

    private static func collapsed(_ text: String) -> String? {
        var value = ""
        value.reserveCapacity(text.count)
        var previousWasSpace = false
        for character in text {
            let isSpace = character == " "
            if isSpace, previousWasSpace { continue }
            previousWasSpace = isSpace
            value.append(character)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        guard !spanning.isEmpty, !body.isEmpty else {
            return orderColumns(body.isEmpty ? lines : body, pageWidth: pageWidth)
        }

        // Bands are *consumed*, not filtered. Selecting `y >= bandStart &&
        // y < spanningLine.y` used to drop any body line whose top fell inside
        // a spanning line's own height — it matched no band and silently
        // vanished from the page, which is real text loss rather than a
        // misordering. Taking each band off the front of a sorted remainder
        // means every line lands in exactly one band.
        var remaining = body.sorted { $0.bounds.y < $1.bounds.y }
        var result: [PDFTextFragment] = []
        for line in spanning {
            let boundary = remaining.firstIndex { $0.bounds.y >= line.bounds.y } ?? remaining.count
            let band = Array(remaining.prefix(boundary))
            remaining.removeFirst(boundary)
            result.append(contentsOf: orderColumns(band, pageWidth: pageWidth))
            result.append(line)
        }
        result.append(contentsOf: orderColumns(remaining, pageWidth: pageWidth))
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
            return byRow(lines, rightToLeft: rightToLeft)
        }

        let centers = clusters.map { values in values.reduce(0, +) / Double(values.count) }
        var columns = Array(repeating: [PDFTextFragment](), count: centers.count)
        for line in lines {
            let column = centers.indices.min(by: {
                abs(centers[$0] - line.bounds.x) < abs(centers[$1] - line.bounds.x)
            }) ?? 0
            columns[column].append(line)
        }

        // Distinct left edges alone do not make a column layout, and acting on
        // them when it isn't one reorders the page badly: a short centred
        // heading sits far enough right to form its own cluster, and treating
        // it as a second column moved it *after* every body line. Real columns
        // run side by side, so demand that each holds a meaningful share of the
        // page and that their vertical spans genuinely overlap.
        guard areSideBySideColumns(columns, lineCount: lines.count) else {
            return byRow(lines, rightToLeft: rightToLeft)
        }

        let orderedColumns = rightToLeft ? columns.reversed() : columns
        return orderedColumns.flatMap { byRow($0, rightToLeft: rightToLeft) }
    }

    private func areSideBySideColumns(
        _ columns: [[PDFTextFragment]], lineCount: Int
    ) -> Bool {
        let candidates = columns.filter { !$0.isEmpty }
        guard candidates.count > 1 else { return false }
        let minimumShare = max(2, Int(Double(lineCount) * 0.15))
        guard candidates.allSatisfy({ $0.count >= minimumShare }) else { return false }

        let spans = candidates.map { column in
            (top: column.map(\.bounds.y).min() ?? 0, bottom: column.map(\.bounds.maxY).max() ?? 0)
        }
        // Every pair must share most of its vertical extent.
        return spans.indices.dropLast().allSatisfy { index in
            let lhs = spans[index]
            let rhs = spans[index + 1]
            let overlap = min(lhs.bottom, rhs.bottom) - max(lhs.top, rhs.top)
            let shorter = min(lhs.bottom - lhs.top, rhs.bottom - rhs.top)
            return shorter > 0 && overlap / shorter > 0.5
        }
    }

    /// Reading order within one column: top to bottom, then along each row.
    ///
    /// Rows are found by **vertical overlap**, not by comparing tops. Two
    /// fragments of one visual line do not report the same top — a curly quote
    /// and body text come from different fonts, so their bounds origins differ
    /// by a fraction of a point. Bucketing `y` (which this did) put those two
    /// halves in different rows whenever the fraction straddled a bucket
    /// boundary, and the later-bucketed half then sorted after the whole rest
    /// of the line: `‘Khalistan’. This demand…` came out as `This demand…
    /// ‘Khalistan’`. Comparing tops with an epsilon instead is no good either —
    /// `abs(a.y - b.y) > 2` is non-transitive, so `sorted` may order near-equal
    /// tops arbitrarily. Assigning an integer row up front gives a strict weak
    /// ordering *and* survives sub-point differences within a row.
    private func byRow(
        _ lines: [PDFTextFragment], rightToLeft: Bool
    ) -> [PDFTextFragment] {
        guard lines.count > 1 else { return lines }
        let sorted = lines.sorted { $0.bounds.y < $1.bounds.y }
        var rows: [Int] = []
        rows.reserveCapacity(sorted.count)
        var row = 0
        var top = sorted[0].bounds.y
        var bottom = sorted[0].bounds.maxY
        for line in sorted {
            let overlap = min(bottom, line.bounds.maxY) - max(top, line.bounds.y)
            let shorter = min(bottom - top, line.bounds.height)
            if shorter > 0, overlap / shorter > 0.5 {
                bottom = max(bottom, line.bounds.maxY)
            } else {
                row += 1
                top = line.bounds.y
                bottom = line.bounds.maxY
            }
            rows.append(row)
        }
        return zip(rows, sorted)
            .sorted { lhs, rhs in
                guard lhs.0 == rhs.0 else { return lhs.0 < rhs.0 }
                return rightToLeft
                    ? lhs.1.bounds.x > rhs.1.bounds.x
                    : lhs.1.bounds.x < rhs.1.bounds.x
            }
            .map(\.1)
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
