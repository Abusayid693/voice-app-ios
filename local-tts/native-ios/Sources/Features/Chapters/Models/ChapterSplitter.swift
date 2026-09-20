import Foundation

/// Splits saved text into chapters of at most ~2000 words each — the unit
/// Generate/Play act on, one layer above `KokoroTextChunker`'s much
/// smaller synthesis chunks. Packs whole paragraphs greedily so a chapter
/// break lands on a paragraph boundary wherever possible; a single
/// over-long paragraph falls back to sentence packing (reusing
/// `KokoroTextChunker.sentenceRanges`, the same boundary logic synthesis
/// chunking already relies on), and a pathological single sentence longer
/// than the whole budget falls back to word packing.
enum ChapterSplitter {
    static let defaultMaxWords = 2000

    static func split(_ text: String, maxWords: Int = defaultMaxWords) -> [Chapter] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chapterTexts: [String] = []
        var current: [String] = []
        var currentWordCount = 0

        func flush() {
            guard !current.isEmpty else { return }
            chapterTexts.append(current.joined(separator: "\n\n"))
            current = []
            currentWordCount = 0
        }

        for paragraph in splitIntoParagraphs(trimmed) {
            let count = wordCount(paragraph)
            if count > maxWords {
                flush()
                chapterTexts.append(contentsOf: splitOverlongParagraph(paragraph, maxWords: maxWords))
                continue
            }
            if current.isEmpty || currentWordCount + count <= maxWords {
                current.append(paragraph)
                currentWordCount += count
            } else {
                flush()
                current = [paragraph]
                currentWordCount = count
            }
        }
        flush()

        return chapterTexts.enumerated().map { index, text in
            Chapter(index: index, title: "Chapter \(index + 1)", text: text)
        }
    }

    // A line ending in sentence-terminal punctuation reads as a complete
    // thought — text formatted one-sentence-per-line (no blank lines
    // between paragraphs) relies on exactly this to mean "new paragraph."
    // A line that doesn't end this way is a mid-sentence wrap instead, and
    // stays a soft line break within the same paragraph.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    private static func splitIntoParagraphs(_ text: String) -> [String] {
        let paragraphs =
            text
            .components(separatedBy: .newlines)
            .reduce(into: [String]()) { result, line in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty {
                    result.append("")
                } else if result.isEmpty || result[result.count - 1].isEmpty {
                    result.append(trimmedLine)
                } else if let last = result[result.count - 1].last, sentenceTerminators.contains(last) {
                    // Previous line ended a sentence — treat this break as
                    // a new paragraph, same as a blank line would.
                    result.append(trimmedLine)
                } else {
                    // "\n", not " " — a single Return inside a paragraph is
                    // a real line break, not a word-join.
                    result[result.count - 1] += "\n" + trimmedLine
                }
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.isEmpty ? [text] : paragraphs
    }

    // Packs sentences by extending a range over `paragraph` (like
    // KokoroTextChunker.chunk) rather than joining trimmed sentence
    // strings, so whitespace/newlines between sentences survive verbatim.
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
            let sentence = paragraph[sentenceRange]
            let count = wordCount(String(sentence))
            if count > maxWords {
                flush()
                pieces.append(contentsOf: splitByWords(String(sentence), maxWords: maxWords))
                continue
            }
            if let existing = current {
                if currentWordCount + count <= maxWords {
                    current = existing.lowerBound..<sentenceRange.upperBound
                    currentWordCount += count
                } else {
                    flush()
                    current = sentenceRange
                    currentWordCount = count
                }
            } else {
                current = sentenceRange
                currentWordCount = count
            }
        }
        flush()
        return pieces
    }

    private static func splitByWords(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return stride(from: 0, to: words.count, by: maxWords).map { start in
            words[start..<min(start + maxWords, words.count)].joined(separator: " ")
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
