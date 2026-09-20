import Foundation

/// Splits long text into pieces that fit Kokoro-ANE's hard 510-phoneme cap
/// per `synthesize()` call. Kokoro ships no chunker of its own, so this
/// stands in for one — phoneme count isn't knowable without running G2P, so
/// it uses a conservative character budget instead, and prefers sentence
/// boundaries (falling back to word boundaries for a single very long
/// sentence) so a chunk break doesn't land mid-sentence unless it has to.
enum KokoroTextChunker {
    /// ~350 characters comfortably clears 510 phonemes with headroom
    /// (English rarely exceeds ~1.3 phonemes per character including
    /// spaces).
    static let maxChunkLength = 350

    static func chunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var current: Range<String.Index>?

        func flush() {
            guard let range = current else { return }
            let value = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { chunks.append(value) }
            current = nil
        }

        for sentenceRange in sentenceRanges(in: trimmed) {
            let sentenceLength = trimmed.distance(from: sentenceRange.lowerBound, to: sentenceRange.upperBound)
            if sentenceLength > maxChunkLength {
                flush()
                chunks.append(contentsOf: splitByWords(String(trimmed[sentenceRange])))
                continue
            }
            if let existing = current {
                let extended = existing.lowerBound..<sentenceRange.upperBound
                let extendedLength = trimmed.distance(from: extended.lowerBound, to: extended.upperBound)
                if extendedLength <= maxChunkLength {
                    current = extended
                } else {
                    flush()
                    current = sentenceRange
                }
            } else {
                current = sentenceRange
            }
        }
        flush()
        return chunks
    }

    // Not private: ChapterSplitter reuses this same sentence-boundary logic
    // for packing paragraphs into chapters. Returns ranges (not trimmed
    // strings) so callers can pack sentences by extending a span over the
    // original text — the whitespace/newlines between sentences ride along
    // in the span verbatim instead of needing to be reconstructed with a
    // guessed separator.
    static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) {
            substring, range, _, _ in
            guard let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            ranges.append(range)
        }
        return ranges.isEmpty ? [text.startIndex..<text.endIndex] : ranges
    }

    private static func splitByWords(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= maxChunkLength {
                current += " " + word
            } else {
                chunks.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
