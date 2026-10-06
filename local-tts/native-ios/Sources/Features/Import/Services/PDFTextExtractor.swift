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
                    fontName: typography.name, fontSize: typography.size,
                    weight: typography.weight, fontClass: typography.fontClass)
            }

            return PDFPageContent(
                pageIndex: index, pageWidth: visualSize.width, pageHeight: visualSize.height,
                lines: order(
                    lines: mergingSplitLines(deduplicatingOverlaps(lines)),
                    pageWidth: visualSize.width))
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
        name: String?, size: Double, weight: ReaderFontWeight, fontClass: ReaderFontClass
    ) {
        guard let attributedText, attributedText.length > 0 else {
            return (nil, 0, .regular, .serif)
        }
        var coverage: [Int: (font: UIFont, length: Int)] = [:]
        let whole = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let key = font.hashValue
            coverage[key, default: (font, 0)].length += range.length
        }
        guard let dominant = coverage.values.max(by: { $0.length < $1.length })?.font else {
            return (nil, 0, .regular, .serif)
        }
        return (
            dominant.fontName, Double(dominant.pointSize), weight(of: dominant),
            fontClass(of: dominant)
        )
    }

    /// Reads a face's weight, preferring its *name* over its descriptor.
    ///
    /// That order looks backwards and isn't: an embedded PDF font routinely
    /// ships with no weight trait and no `.traitBold` at all, while its name
    /// ("…-Semibold", "…-Light") is set correctly, because the name is what the
    /// producing application wrote and the traits are what CoreText guessed.
    /// Order within the name matters too — "Semibold" and "ExtraBold" both
    /// contain "Bold", so the more specific tokens have to be tested first.
    private func weight(of font: UIFont) -> ReaderFontWeight {
        let name = font.fontName.lowercased()
        let tokens: [(needles: [String], weight: ReaderFontWeight)] = [
            (["extrabold", "ultrabold", "black", "heavy"], .heavy),
            (["semibold", "demibold", "demi"], .semibold),
            (["bold"], .bold),
            (["medium"], .medium),
            (["ultralight", "extralight", "thin", "light"], .light),
        ]
        for token in tokens where token.needles.contains(where: name.contains) {
            return token.weight
        }
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) { return .bold }
        // Only trusted once the name says nothing: normalized -1...1, 0 regular.
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        guard let measured = traits?[.weight] as? Double else { return .regular }
        switch measured {
        case ..<(-0.2): return .light
        case ..<0.2: return .regular
        case ..<0.3: return .medium
        case ..<0.4: return .semibold
        case ..<0.6: return .bold
        default: return .heavy
        }
    }

    /// Serif is the default rather than sans: books are overwhelmingly set in
    /// one, and a wrong guess toward serif is the quieter failure in a reader.
    private func fontClass(of font: UIFont) -> ReaderFontClass {
        let name = font.fontName.lowercased()
        if font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
            || ["mono", "courier", "consol", "menlo"].contains(where: name.contains)
        {
            return .monospaced
        }
        let sans = [
            "sans", "helvetica", "arial", "calibri", "verdana", "tahoma", "futura",
            "gill", "frutiger", "myriad", "lato", "roboto", "segoe", "avenir",
            "franklin", "univers", "optima", "gotham", "proxima",
        ]
        return sans.contains(where: name.contains) ? .sansSerif : .serif
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
            // A line break *inside* one extracted line is PDFKit reporting a
            // run it could not keep in order, not a real break — a decorative
            // chapter title came back as "nnie\nA". Downstream a newline means
            // a paragraph boundary (`makeReaderPage` joins paragraphs with
            // "\n\n", and `spokenText` now closes a sentence at each one), so
            // leaving it in turns one confused line into several.
            case 0x0009, 0x000A, 0x000D, 0x00A0, 0x2000...0x200A, 0x2028, 0x2029,
                 0x202F, 0x205F, 0x3000:
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

    /// Drops selections that claim the exact same rectangle as another.
    ///
    /// A decorative chapter title drawn with swash capitals came back as four
    /// selections over one identical rect, each holding a scrambled slice of
    /// the same word — `nnie A`, `e A`, `e A`, `e A`. Identical bounds mean
    /// PDFKit has read one run several ways, not that there are several runs,
    /// so the longest is kept and the rest discarded. That stops one confused
    /// line from becoming four, but leaves it scrambled: the word order is only
    /// recoverable one level further down, from per-glyph positions this
    /// selection-based pipeline never sees (`page.characterBounds(at:)`, which
    /// is indexed by *glyph* — so a page's inserted newlines shift every index
    /// after the first one).
    private func deduplicatingOverlaps(_ lines: [PDFTextFragment]) -> [PDFTextFragment] {
        guard lines.count > 1 else { return lines }
        var kept: [PDFTextFragment] = []
        for line in lines.sorted(by: { $0.text.count > $1.text.count }) {
            let duplicate = kept.contains { other in
                abs(other.bounds.x - line.bounds.x) < 0.5
                    && abs(other.bounds.y - line.bounds.y) < 0.5
                    && abs(other.bounds.width - line.bounds.width) < 0.5
                    && abs(other.bounds.height - line.bounds.height) < 0.5
            }
            if !duplicate { kept.append(line) }
        }
        return kept
    }

    /// Rejoins pieces of one visual line that `selectionsByLine()` handed back
    /// separately — a style change mid-line, or a short trailing word.
    ///
    /// This has to run *before* `order`, because a stray piece wrecks column
    /// inference rather than merely looking untidy. On a page whose body line
    /// ends `…numbers. Today,` + `Mike` as two selections, that lone `Mike` sits
    /// far to the right of its own line, so `orderColumns` clusters it as a
    /// third column of its own. `areSideBySideColumns` then rejects the *entire*
    /// layout — it requires every cluster to hold at least a couple of lines —
    /// and falls back to row ordering, which reads a real two-column region
    /// (a pull-quote beside body text) straight across: quote line, body line,
    /// quote line, body line. `PDFParagraphAssembler.combining` would have
    /// merged the same pieces, but it only runs after ordering, by which point
    /// the interleaving has already happened.
    ///
    /// The gap ceiling is deliberately far tighter than the assembler's: that
    /// one runs once columns are already separated, while this runs before, so
    /// it must stay well under a gutter. Measured across the pull-quote pages
    /// this was written for, a word space runs ~0.22em while the tightest
    /// gutter is ~0.75em of the quote's own size — which is why 0.5em, and why
    /// the font-size test below carries most of the weight rather than the gap
    /// alone.
    private func mergingSplitLines(_ lines: [PDFTextFragment]) -> [PDFTextFragment] {
        guard lines.count > 1 else { return lines }
        var remaining = lines.sorted {
            $0.bounds.y == $1.bounds.y ? $0.bounds.x < $1.bounds.x : $0.bounds.y < $1.bounds.y
        }
        var result: [PDFTextFragment] = []
        while !remaining.isEmpty {
            var current = remaining.removeFirst()
            var merged = true
            while merged {
                merged = false
                for index in remaining.indices where sharesRow(current, remaining[index]) {
                    let candidate = remaining[index]
                    // Pieces of one line share a size. A pull-quote beside body
                    // text does not, and that is the case this must never merge:
                    // one page sets its quote at 14pt against 12pt body with
                    // only 10.4pt of gutter, which no gap rule alone separates
                    // from an ordinary word space.
                    let sizeGap = abs(current.fontSize - candidate.fontSize)
                    guard sizeGap <= max(current.fontSize, candidate.fontSize) * 0.1
                    else { continue }
                    let gap = candidate.bounds.x - current.bounds.maxX
                    let reference = max(current.fontSize, 8)
                    // Allow a hair of overlap: adjoining glyph runs can report
                    // bounds that touch or cross by a fraction of a point.
                    guard gap >= -1, gap < reference * 0.5 else { continue }
                    current = joining(current, candidate, gap: gap, reference: reference)
                    remaining.remove(at: index)
                    merged = true
                    break
                }
            }
            result.append(current)
        }
        return result
    }

    private func sharesRow(_ lhs: PDFTextFragment, _ rhs: PDFTextFragment) -> Bool {
        let overlap = min(lhs.bounds.maxY, rhs.bounds.maxY) - max(lhs.bounds.y, rhs.bounds.y)
        let shorter = min(lhs.bounds.height, rhs.bounds.height)
        return shorter > 0 && overlap / shorter > 0.5
    }

    private func joining(
        _ lhs: PDFTextFragment, _ rhs: PDFTextFragment, gap: Double, reference: Double
    ) -> PDFTextFragment {
        // Only genuinely abutting pieces join without a space — a closing quote
        // and the period that follows it, say. This book's word space measures
        // ~0.22em, so a threshold at that figure sat right on top of it and
        // dropped real spaces ("important" + "to be" -> "importantto be");
        // 0.08em separates a touching pair from a spaced one with room either
        // side.
        let separator = gap > reference * 0.08 ? " " : ""
        let x = min(lhs.bounds.x, rhs.bounds.x)
        let y = min(lhs.bounds.y, rhs.bounds.y)
        let union = CGRect(
            x: x, y: y,
            width: max(lhs.bounds.maxX, rhs.bounds.maxX) - x,
            height: max(lhs.bounds.maxY, rhs.bounds.maxY) - y)
        // Typography follows whichever piece carries more of the text, so a
        // one-word tail cannot redefine the line's size or weight.
        let dominant = lhs.text.count >= rhs.text.count ? lhs : rhs
        return PDFTextFragment(
            text: lhs.text + separator + rhs.text, pageIndex: lhs.pageIndex,
            bounds: PDFNormalizedRect(union), fontName: dominant.fontName,
            fontSize: dominant.fontSize, weight: dominant.weight,
            fontClass: dominant.fontClass)
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
