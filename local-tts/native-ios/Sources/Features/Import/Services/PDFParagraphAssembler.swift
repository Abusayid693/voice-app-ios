import Foundation
import UIKit

/// Decides whether a hyphen at a line wrap was the typesetter's or the
/// author's.
///
/// Geometry cannot tell these apart — "under-"/"stand" and "well-"/"known" both
/// sit at the right margin with a lowercase continuation — so this asks a
/// lexicon instead. `UITextChecker` is the one offline dictionary available to
/// us. If the halves joined make a real word the hyphen was a wrap artefact; if
/// they don't but each half is itself a word, the author wrote the hyphen.
/// Anything undecidable joins, because typesetter hyphenation is by far the
/// more common case in justified text.
///
/// Answers are cached: a justified book hyphenates every few lines, and the
/// same fragments recur across hundreds of pages.
final class WrapHyphenResolver {
    private let checker = UITextChecker()
    private let language: String?
    private var knownWords: [String: Bool] = [:]

    init() {
        let available = UITextChecker.availableLanguages
        let preferred = Locale.current.language.languageCode?.identifier
        language = available.first { preferred.map($0.hasPrefix) ?? false }
            ?? available.first { $0.hasPrefix("en") }
            ?? available.first
    }

    func shouldJoin(prefix: String, suffix: String) -> Bool {
        // Only Latin script is worth asking about; anything else defaults to
        // joining rather than being judged by an English dictionary.
        guard language != nil,
              prefix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isASCII)
        else { return true }
        if isWord(prefix + suffix) { return true }
        return !(isWord(prefix) && isWord(suffix))
    }

    private func isWord(_ word: String) -> Bool {
        guard let language else { return false }
        if let cached = knownWords[word] { return cached }
        let range = NSRange(location: 0, length: word.utf16.count)
        let misspelled = checker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: language)
        let result = misspelled.location == NSNotFound
        knownWords[word] = result
        return result
    }
}

/// Groups one PDF page's ordered text lines into reading-order paragraphs.
///
/// Pure layout analysis over the geometry `PDFKitTextExtractor` already
/// captured — no PDFKit, no I/O — so `PDFProcessingActor` keeps only
/// orchestration, checkpointing, and deciding which lines are junk.
///
/// **Every threshold is measured, not fixed.** That is the whole point of this
/// type. The version this replaced compared a line gap against the previous
/// line's own glyph box (`bounds.height * 1.35`), but `PDFSelection.bounds`
/// hugs the glyphs, so a line with no ascenders or descenders ("was a now one")
/// reported a much shorter box than its neighbours, the threshold collapsed to
/// its floor, and an ordinary line gap split the paragraph — splits landed on
/// whichever lines happened to lack tall letters. Measuring top-to-top against
/// the run's own median leading is immune to that.
///
/// It also had only one break signal (vertical gap), so the very common book
/// convention of marking a paragraph with a first-line indent and no extra
/// leading merged paragraphs together. `Metrics` plus the ordered rules in
/// `startsNewParagraph` cover indent, ragged last line, headings and lists.
struct PDFParagraphAssembler {
    private let hyphens = WrapHyphenResolver()

    /// Layout facts measured from a run of lines, which the break rules are
    /// all expressed relative to.
    private struct Metrics {
        let bodyFontSize: Double
        /// What a heading is measured *against*, and what its scale is
        /// expressed relative to. Normally the whole document's body size, so a
        /// chapter-opener page — which contains no body text at all, and whose
        /// own modal size is therefore the heading's — still recognises its
        /// title. Falls back to `bodyFontSize` when the document's is unknown.
        let referenceFontSize: Double
        /// Median top-to-top distance between consecutive lines, i.e. real
        /// leading — deliberately not a bottom-to-top gap.
        let leading: Double
        let columnLeft: Double
        let columnRight: Double
        /// True when most lines end flush at the right edge. The ragged-last
        /// -line rule is meaningless without this, since in unjustified text
        /// every line is short.
        let isJustified: Bool

        var columnWidth: Double { max(1, columnRight - columnLeft) }
    }

    func paragraphs(
        from lines: [PDFTextFragment], pageIndex: Int, pageWidth: Double,
        documentBodyFontSize: Double = 0
    ) -> [PDFParagraph] {
        guard !lines.isEmpty else { return [] }
        let lines = mergedLines(lines)
        // Page-wide metrics back-fill any run too short to measure its own.
        let pageMetrics = metrics(for: lines, fallback: nil, reference: documentBodyFontSize)
        return columnRuns(in: lines, pageWidth: pageWidth).flatMap { run in
            paragraphs(inRun: run, pageIndex: pageIndex, fallback: pageMetrics)
        }
    }

    // MARK: - Same-row fragments

    /// Stitches fragments that share a visual row back into one line.
    ///
    /// `PDFSelection.selectionsByLine()` does not reliably return one selection
    /// per visual line. A font change mid-line, a superscript footnote marker,
    /// a drop cap, or a closing quote mark can each come back as its own
    /// fragment — and a trailing one sits at the far *right* of the row it
    /// belongs to. Left alone its left edge looks like a different column, so it
    /// became its own paragraph: a line ending in `.'` rendered as a blank line
    /// followed by a lone `'`.
    ///
    /// Fragments arrive already row-ordered from `PDFKitTextExtractor.order`, so
    /// same-row pieces are adjacent and a single pass is enough.
    private func mergedLines(_ lines: [PDFTextFragment]) -> [PDFTextFragment] {
        var merged: [PDFTextFragment] = []
        for line in lines {
            // Either arrival order is accepted. The two halves of a row can
            // reach here right-hand-first if anything upstream orders them by
            // a top edge, since fragments in different fonts do not report the
            // same top — insisting on left-to-right made the merge silently
            // fail exactly when it was needed. Reordering only this adjacent
            // pair keeps a genuine two-column page (emitted column by column,
            // deliberately not in row order) untouched.
            guard let previous = merged.last, sharesRow(previous, line) else {
                merged.append(line)
                continue
            }
            let ordered = line.bounds.x < previous.bounds.x
                ? (left: line, right: previous)
                : (left: previous, right: line)
            guard let combined = combining(ordered.left, ordered.right) else {
                merged.append(line)
                continue
            }
            merged[merged.count - 1] = combined
        }
        return merged
    }

    private func sharesRow(_ lhs: PDFTextFragment, _ rhs: PDFTextFragment) -> Bool {
        let overlap = min(lhs.bounds.maxY, rhs.bounds.maxY) - max(lhs.bounds.y, rhs.bounds.y)
        let shorter = min(lhs.bounds.height, rhs.bounds.height)
        return shorter > 0 && overlap / shorter > 0.5
    }

    private func combining(
        _ lhs: PDFTextFragment, _ rhs: PDFTextFragment
    ) -> PDFTextFragment? {
        let gap = rhs.bounds.x - lhs.bounds.maxX
        let reference = max(lhs.fontSize, 8)
        // The gap ceiling is what keeps a two-column layout's two columns apart:
        // a gutter is far wider than any inter-word space, so two blocks that
        // merely sit at the same height are never merged.
        guard rhs.bounds.x >= lhs.bounds.x, gap < max(12, reference * 2) else { return nil }
        // No space when the pieces abut — that is one word PDFKit split, so
        // "nice." + "'" has to rejoin as "nice.'" rather than "nice. '".
        let separator = gap > reference * 0.22 ? " " : ""
        let x = min(lhs.bounds.x, rhs.bounds.x)
        let y = min(lhs.bounds.y, rhs.bounds.y)
        let union = CGRect(
            x: x, y: y,
            width: max(lhs.bounds.maxX, rhs.bounds.maxX) - x,
            height: max(lhs.bounds.maxY, rhs.bounds.maxY) - y)
        // Typography follows whichever piece carries more of the text, so a
        // one-character fragment can't redefine the line's size or weight.
        let dominant = lhs.text.count >= rhs.text.count ? lhs : rhs
        return PDFTextFragment(
            text: lhs.text + separator + rhs.text, pageIndex: lhs.pageIndex,
            bounds: PDFNormalizedRect(union), fontName: dominant.fontName,
            fontSize: dominant.fontSize, isBold: dominant.isBold)
    }

    /// Character-weighted modal font size across every line of a document —
    /// `PDFProcessingActor` computes this once over the checkpointed page
    /// geometry and feeds it back in, so heading scale is measured against the
    /// same reference on every page.
    func bodyFontSize(across lines: [PDFTextFragment]) -> Double {
        modalFontSize(lines)
    }

    // MARK: - Runs

    /// Splits the ordered lines wherever the left edge jumps far enough to be
    /// a different column, so each column's metrics and paragraphs are worked
    /// out separately. A page-wide `columnRight` would otherwise make every
    /// line of a two-column layout's left column look ragged.
    private func columnRuns(
        in lines: [PDFTextFragment], pageWidth: Double
    ) -> [[PDFTextFragment]] {
        let columnGap = max(48, pageWidth * 0.12)
        var runs: [[PDFTextFragment]] = []
        for line in lines {
            if let previous = runs.last?.last,
               abs(line.bounds.x - previous.bounds.x) <= columnGap
            {
                runs[runs.count - 1].append(line)
            } else {
                runs.append([line])
            }
        }
        return runs
    }

    private func paragraphs(
        inRun run: [PDFTextFragment], pageIndex: Int, fallback: Metrics
    ) -> [PDFParagraph] {
        let metrics = metrics(for: run, fallback: fallback)
        var result: [PDFParagraph] = []
        var current: [PDFTextFragment] = []

        func flush() {
            guard let first = current.first else { return }
            let joined = joined(current)
            if !joined.text.isEmpty {
                // The longest line represents the paragraph's typography
                // better than its first one, which may be a short opener.
                let dominant = current.max { $0.text.count < $1.text.count } ?? first
                let heading = isHeading(dominant, metrics: metrics)
                result.append(PDFParagraph(
                    text: joined.text, pageIndex: pageIndex, top: first.bounds.y,
                    fontSize: dominant.fontSize, isBold: dominant.isBold,
                    isHeading: heading,
                    fontScale: heading ? headingScale(dominant, metrics: metrics) : 1,
                    lineSpans: joined.spans))
            }
            current = []
        }

        for line in run {
            if let previous = current.last,
               startsNewParagraph(current: line, previous: previous, metrics: metrics)
            {
                flush()
            }
            current.append(line)
        }
        flush()
        return result
    }

    // MARK: - Break rules

    private func startsNewParagraph(
        current: PDFTextFragment, previous: PDFTextFragment, metrics: Metrics
    ) -> Bool {
        let currentIsHeading = isHeading(current, metrics: metrics)
        let previousIsHeading = isHeading(previous, metrics: metrics)

        // 1. A heading never shares a paragraph with body text. This replaces a
        // bare `isBold !=` test, which split a paragraph whenever one line's
        // dominant run happened to differ in weight.
        if currentIsHeading != previousIsHeading { return true }

        // 2. Extra leading between the two lines.
        if metrics.leading > 0.5,
           current.bounds.y - previous.bounds.y > metrics.leading * 1.5
        {
            return true
        }

        // 3. The previous line stopped short of the right edge — in justified
        // text the single most reliable end-of-paragraph signal there is. A
        // wrap hyphen means the word continues, so it is never an ending, and
        // neither is a next line that plainly continues a sentence.
        if metrics.isJustified, !previousIsHeading,
           !endsWithWrapHyphen(previous.text),
           !continuesPreviousLine(current.text),
           previous.bounds.maxX < metrics.columnRight - metrics.columnWidth * 0.06
        {
            return true
        }

        // 4. First-line indent, the convention the old code missed entirely.
        // Requiring the previous line to sit at the margin is what stops a
        // wholly indented block quote from breaking on every one of its lines.
        let indent = max(3, metrics.bodyFontSize * 0.5)
        let atMargin = max(2, metrics.bodyFontSize * 0.2)
        if current.bounds.x - metrics.columnLeft > indent,
           previous.bounds.x - metrics.columnLeft <= atMargin
        {
            return true
        }

        // 5. A new list item.
        if startsWithListMarker(current.text) { return true }

        // 6. Font size change, relative to body size rather than a flat 2pt.
        if metrics.bodyFontSize > 0,
           abs(current.fontSize - previous.fontSize) > max(1, metrics.bodyFontSize * 0.12)
        {
            return true
        }

        return false
    }

    private func isHeading(_ line: PDFTextFragment, metrics: Metrics) -> Bool {
        // A drop cap is a single huge glyph on its own line — by size alone the
        // most heading-looking thing on a novel's page, and never a heading.
        guard line.text.count > 2 else { return false }
        if metrics.referenceFontSize > 0,
           line.fontSize >= metrics.referenceFontSize * 1.15
        {
            return true
        }
        // Weight and capitalisation only read as a heading on a short line;
        // a full-measure bold line is emphasised body text.
        let isShort = line.bounds.maxX < metrics.columnRight - metrics.columnWidth * 0.15
        guard isShort else { return false }
        return line.isBold || isAllCaps(line.text)
    }

    /// How much larger this heading was than the document's body text, clamped:
    /// a cover-page title set at 5x would otherwise dwarf the reader, and a
    /// heading distinguished only by weight legitimately scores 1.0.
    private func headingScale(_ line: PDFTextFragment, metrics: Metrics) -> Double {
        guard metrics.referenceFontSize > 0, line.fontSize > 0 else { return 1 }
        return min(2, max(1, line.fontSize / metrics.referenceFontSize))
    }

    /// A line that opens mid-sentence is never the start of a paragraph. The
    /// punctuation case is the one that matters in practice: when PDFKit splits
    /// a line after a quoted word, the remainder begins with the sentence's own
    /// full stop — `‘Khalistan’` / `. This demand…` — and the short first half
    /// would otherwise look like a paragraph ending.
    private func continuesPreviousLine(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isLowercase || ".,;:!?".contains(first)
    }

    private func isAllCaps(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    /// Bullets, `1.`/`1)` up to three digits (so a year opening a sentence is
    /// not mistaken for a list), and `a)` but never `a.` — the latter would
    /// match an initial like "J. Alfred" starting a line.
    private static let listMarker = #"^\s*(?:[•◦▪‣·*]|\(?\d{1,3}[.)]|\(?[a-z]\))\s"#

    private func startsWithListMarker(_ text: String) -> Bool {
        text.range(of: Self.listMarker, options: .regularExpression) != nil
    }

    // MARK: - Metrics

    private func metrics(
        for lines: [PDFTextFragment], fallback: Metrics?, reference: Double = 0
    ) -> Metrics {
        let measuredFont = modalFontSize(lines)
        let bodyFontSize = measuredFont > 0 ? measuredFont : (fallback?.bodyFontSize ?? 0)
        // The document's figure wins wherever it is known, so every page scores
        // headings against the same body size.
        let inherited = reference > 0 ? reference : (fallback?.referenceFontSize ?? 0)
        let referenceFontSize = inherited > 0 ? inherited : bodyFontSize
        let leading = medianLeading(lines)
            ?? fallback?.leading
            ?? (bodyFontSize > 0 ? bodyFontSize * 1.2 : 0)

        // Too few lines to locate a margin or a right edge; the page's own
        // figures are a better guess than this run's.
        guard lines.count >= 4 else {
            return Metrics(
                bodyFontSize: bodyFontSize, referenceFontSize: referenceFontSize,
                leading: leading,
                columnLeft: fallback?.columnLeft ?? modalLeftEdge(lines),
                columnRight: fallback?.columnRight ?? percentile(lines.map(\.bounds.maxX), 0.95),
                isJustified: fallback?.isJustified ?? false)
        }

        let columnLeft = modalLeftEdge(lines)
        let columnRight = percentile(lines.map(\.bounds.maxX), 0.95)
        let width = max(1, columnRight - columnLeft)
        let flush = lines.filter { $0.bounds.maxX >= columnRight - width * 0.02 }.count
        return Metrics(
            bodyFontSize: bodyFontSize, referenceFontSize: referenceFontSize,
            leading: leading,
            columnLeft: columnLeft, columnRight: columnRight,
            isJustified: Double(flush) / Double(lines.count) > 0.6)
    }

    /// Weighted by characters, so a page's body size wins over a few large
    /// heading lines.
    private func modalFontSize(_ lines: [PDFTextFragment]) -> Double {
        var weights: [Double: Int] = [:]
        for line in lines where line.fontSize > 0 {
            weights[(line.fontSize * 2).rounded() / 2, default: 0] += line.text.count
        }
        return weights.max {
            $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
        }?.key ?? 0
    }

    /// The median absorbs the minority of pairs that straddle a paragraph
    /// break, so this lands on the within-paragraph leading.
    private func medianLeading(_ lines: [PDFTextFragment]) -> Double? {
        let deltas = zip(lines, lines.dropFirst())
            .map { $1.bounds.y - $0.bounds.y }
            .filter { $0 > 0.5 }
            .sorted()
        guard !deltas.isEmpty else { return nil }
        return deltas[deltas.count / 2]
    }

    /// Ties go to the smaller edge: that is the margin, not an indent.
    private func modalLeftEdge(_ lines: [PDFTextFragment]) -> Double {
        var counts: [Double: Int] = [:]
        for line in lines {
            counts[(line.bounds.x / 2).rounded() * 2, default: 0] += 1
        }
        return counts.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }?.key ?? (lines.map(\.bounds.x).min() ?? 0)
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = (Double(sorted.count - 1) * fraction).rounded()
        return sorted[min(sorted.count - 1, max(0, Int(position)))]
    }

    // MARK: - Joining

    /// Hyphens a typesetter may have inserted at a wrap. The soft hyphen is
    /// here defensively — `PDFKitTextExtractor.normalizedText` already turns a
    /// trailing one into "-" and drops interior ones.
    private static let wrapHyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{00AD}"]

    private func endsWithWrapHyphen(_ text: String) -> Bool {
        text.last.map(Self.wrapHyphens.contains) ?? false
    }

    /// Joins a paragraph's lines, recording where each one landed so the reader
    /// can map text back to the page image. The offsets have to be tracked here
    /// rather than recovered later: this is the last point at which a line's
    /// text and its rectangle are still associated, and joining rewrites the
    /// text — it merges fragments, drops wrap hyphens and inserts separators.
    private func joined(
        _ lines: [PDFTextFragment]
    ) -> (text: String, spans: [PDFParagraphLineSpan]) {
        var text = ""
        var spans: [PDFParagraphLineSpan] = []

        func appendSpan(start: Int, _ line: PDFTextFragment) {
            spans.append(PDFParagraphLineSpan(
                start: start, length: line.text.count, bounds: line.bounds))
        }

        for line in lines {
            guard !text.isEmpty else {
                appendSpan(start: 0, line)
                text = line.text
                continue
            }
            if endsWithWrapHyphen(text) {
                // A hyphen at a wrap never has a space after it, whether or
                // not the word itself should be rejoined — so "1990-"/"1995"
                // becomes "1990-1995" rather than "1990- 1995".
                if let rejoined = dehyphenated(text, joining: line.text) {
                    // The hyphen left with the previous line, so that span
                    // covers one character fewer and this one starts there.
                    if let previous = spans.popLast() {
                        spans.append(PDFParagraphLineSpan(
                            start: previous.start, length: max(0, previous.length - 1),
                            bounds: previous.bounds))
                    }
                    appendSpan(start: text.count - 1, line)
                    text = rejoined
                } else {
                    appendSpan(start: text.count, line)
                    text += line.text
                }
                continue
            }
            if let last = text.last, let next = line.text.first, isCJK(last), isCJK(next) {
                appendSpan(start: text.count, line)
                text += line.text
            } else {
                text += " "
                appendSpan(start: text.count, line)
                text += line.text
            }
        }

        // Every fragment is trimmed by `normalizedText`, so this should never
        // fire — but if it did, every recorded offset would shift. Drop the
        // spans rather than point the reader at the wrong part of the page.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == text ? (text, spans) : (trimmed, [])
    }

    /// Drops a wrap hyphen only when the break is genuinely mid-word: a
    /// lowercase continuation (so "Anglo-"/"Saxon" keeps its hyphen), at least
    /// two letters before the hyphen (so "e-mail" keeps its, and a digit before
    /// it never qualifies), and a lexicon that agrees the halves make one word.
    private func dehyphenated(_ text: String, joining next: String) -> String? {
        guard let following = next.first, following.isLowercase else { return nil }
        let stem = text.dropLast()
        let prefix = String(stem.reversed().prefix(while: \.isLetter).reversed())
        guard prefix.count >= 2 else { return nil }
        let suffix = String(next.prefix(while: \.isLetter))
        guard hyphens.shouldJoin(prefix: prefix, suffix: suffix) else { return nil }
        return String(stem) + next
    }

    private func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
