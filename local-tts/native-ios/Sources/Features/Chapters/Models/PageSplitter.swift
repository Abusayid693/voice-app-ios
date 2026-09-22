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
