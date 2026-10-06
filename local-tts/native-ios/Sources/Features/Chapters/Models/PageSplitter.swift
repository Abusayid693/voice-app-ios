import Foundation

/// Splits entered text into reader pages of at most 2,000 words. Paragraph
/// and sentence boundaries are preferred before falling back to word chunks.
enum PageSplitter {
    static let defaultMaxWords = 2_000

    static func split(_ text: String, maxWords: Int = defaultMaxWords) -> [ReaderPage] {
        guard maxWords > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var pageTexts: [String] = []
        var current: [String] = []
        var currentWordCount = 0

        func flush() {
            guard !current.isEmpty else { return }
            pageTexts.append(current.joined(separator: "\n\n"))
            current = []
            currentWordCount = 0
        }

        for paragraph in splitIntoParagraphs(trimmed) {
            let count = wordCount(paragraph)
            if count > maxWords {
                flush()
                pageTexts.append(contentsOf: splitOverlongParagraph(paragraph, maxWords: maxWords))
            } else if current.isEmpty || currentWordCount + count <= maxWords {
                current.append(paragraph)
                currentWordCount += count
            } else {
                flush()
                current = [paragraph]
                currentWordCount = count
            }
        }
        flush()

        return pageTexts.enumerated().map { ReaderPage(index: $0.offset, text: $0.element) }
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    private static func splitIntoParagraphs(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: .newlines).reduce(into: [String]()) { result, line in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                result.append("")
            } else if result.isEmpty || result[result.count - 1].isEmpty {
                result.append(trimmedLine)
            } else if let last = result[result.count - 1].last, sentenceTerminators.contains(last) {
                result.append(trimmedLine)
            } else {
                result[result.count - 1] += "\n" + trimmedLine
            }
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        return paragraphs.isEmpty ? [text] : paragraphs
    }

    private static func splitOverlongParagraph(_ paragraph: String, maxWords: Int) -> [String] {
        var pieces: [String] = []
        var current: Range<String.Index>?
        var currentWordCount = 0

        func flush() {
            guard let range = current else { return }
            pieces.append(String(paragraph[range]).trimmingCharacters(in: .whitespaces))
            current = nil
            currentWordCount = 0
        }

        for sentenceRange in KokoroTextChunker.sentenceRanges(in: paragraph) {
            let count = wordCount(String(paragraph[sentenceRange]))
            if count > maxWords {
                flush()
                pieces.append(contentsOf: splitByWords(String(paragraph[sentenceRange]), maxWords: maxWords))
            } else if let existing = current, currentWordCount + count <= maxWords {
                current = existing.lowerBound..<sentenceRange.upperBound
                currentWordCount += count
            } else {
                flush()
                current = sentenceRange
                currentWordCount = count
            }
        }
        flush()
        return pieces
    }

    private static func splitByWords(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return stride(from: 0, to: words.count, by: maxWords).map { start in
            words[start..<min(start + maxWords, words.count)].joined(separator: " ")
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

extension PageSplitter {
    /// One styled unit of text to pack into pages — generic over whatever
    /// produced it, so this file stays free of any one import format's own
    /// models, the same reason `ReaderTextRect` is its own type rather than
    /// reusing `Features/Import`'s `PDFNormalizedRect`.
    struct StyledUnit {
        let text: String
        /// `nil` renders as plain body — no `ReaderStyledRange` is emitted,
        /// matching `PDFProcessingActor.isPlainBody`'s reason for skipping
        /// an ordinary paragraph: a page with no styling at all is the
        /// common case, and `ChapterPlayerView` already treats an empty
        /// `styledRanges` as a fast path.
        let style: ReaderTextStyle?
    }

    /// Packs pre-structured units (one EPUB *section* — the span between two
    /// chapter boundaries, already cut by `EPUBProcessingActor` at every
    /// spine document and TOC anchor) using the same greedy word-count
    /// packing as `split(_ text:)`, so a long single unit still falls
    /// through to the existing sentence- then word-level fallback rather
    /// than a second implementation of it.
    ///
    /// No tag or page-index map: every chapter boundary already starts its
    /// own call to this function (`EPUBProcessingActor` never spans one call
    /// across two chapters), so a chapter's start page is simply the running
    /// page count before that call — nothing here needs to help resolve it.
    /// `formatVersion` is left at the `ReaderPage` default; the caller
    /// re-stamps it when re-indexing each page onto the book's running total.
    static func split(units: [StyledUnit], maxWords: Int = defaultMaxWords) -> [ReaderPage] {
        guard maxWords > 0, !units.isEmpty else { return [] }

        var pageGroups: [[StyledUnit]] = []
        var current: [StyledUnit] = []
        var currentWordCount = 0

        func flush() {
            guard !current.isEmpty else { return }
            pageGroups.append(current)
            current = []
            currentWordCount = 0
        }

        for unit in units {
            let count = wordCount(unit.text)
            if count > maxWords {
                flush()
                // Each split piece keeps the original unit's style, and
                // becomes its own page — the same shape `split(_ text:)`
                // already gives an overlong paragraph.
                for piece in splitOverlongParagraph(unit.text, maxWords: maxWords) {
                    pageGroups.append([StyledUnit(text: piece, style: unit.style)])
                }
            } else if current.isEmpty || currentWordCount + count <= maxWords {
                current.append(unit)
                currentWordCount += count
            } else {
                flush()
                current = [unit]
                currentWordCount = count
            }
        }
        flush()

        return pageGroups.enumerated().map { pageIndex, group in
            var text = ""
            var styledRanges: [ReaderStyledRange] = []
            for unit in group {
                if !text.isEmpty { text += "\n\n" }
                let base = text.count
                if let style = unit.style {
                    styledRanges.append(ReaderStyledRange(
                        start: base, length: unit.text.count, style: style))
                }
                text += unit.text
            }
            return ReaderPage(index: pageIndex, text: text, styledRanges: styledRanges)
        }
    }
}
