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
        var current = ""

        func flush() {
            let value = current.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { chunks.append(value) }
            current = ""
        }

        for sentence in splitIntoSentences(trimmed) {
            if sentence.count > maxChunkLength {
                flush()
                chunks.append(contentsOf: splitByWords(sentence))
                continue
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= maxChunkLength {
                current += " " + sentence
            } else {
                flush()
                current = sentence
            }
        }
        flush()
        return chunks
    }

    // Not private: ChapterSplitter reuses this same sentence-boundary
    // logic for packing paragraphs into chapters, rather than forking it.
    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) {
            substring, _, _, _ in
            if let substring {
                let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
            }
        }
        return sentences.isEmpty ? [text] : sentences
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
