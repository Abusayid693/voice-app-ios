import FluidAudio
import Foundation

/// One displayed word's start/end within its chunk's audio (seconds,
/// relative to the chunk — chunk audio is never merged into a single file,
/// so this is always the position within that one chunk's own player).
///
/// `precedingSeparator` is the literal whitespace that appeared before this
/// word in the chunk's original text ("" for the first word) — a plain
/// space between ordinary words, but "\n" or "\n\n" across a line/paragraph
/// break. Rendering must reuse this verbatim rather than re-joining words
/// with a hardcoded space, or paragraph breaks collapse the moment a chunk
/// becomes the currently-playing one (the same class of bug as the
/// chunk-text newline fix, reintroduced here since Kokoro's own phonemizer
/// normalizes every word-boundary whitespace to a single space internally —
/// see `splitPreservingSeparators`).
struct WordTiming: Codable, Equatable {
    let word: String
    let precedingSeparator: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Derives exact per-word timings for one synthesis chunk from Kokoro's
/// real per-token duration data — every displayed word gets a timing, even
/// one that expands into several spoken words ("$45" -> "forty five
/// dollars"). No fallback to chunk-level highlighting.
///
/// Why this is possible: the one context-sensitive expansion step (number/
/// date/currency normalization) runs through `NemoTextNormalizer`, which is
/// public — so its output is observable rather than hidden inside
/// synthesis. Everything after that (hyphenated compounds, initialisms,
/// the Swift-side baseline number rules) is verified token-local, so
/// calling `phonemes(for:)` on one word at a time gives reliable group
/// counts. Those counts are then consumed against the REAL per-chunk
/// synthesis's `inputIds`/`predictedDurations` — not re-derived from the
/// isolated calls — so timing stays frame-accurate to what was actually
/// synthesized.
enum WordTimingDeriver {
    /// A word's identity for alignment matching: lowercased, with leading/
    /// trailing punctuation stripped. Deliberately loose — a non-match (any
    /// word containing digits or symbols) is exactly the signal that word
    /// diverged during normalization, which `alignWords` uses to resync.
    static func matchKey(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Aligns each displayed word to the normalized word(s) it expanded
    /// into, via a two-pointer anchor walk: identical words advance both
    /// sides in lockstep; a mismatch scans ahead for where the *next*
    /// displayed word resyncs with the normalized stream, and claims
    /// everything in between for the diverging word. Always returns
    /// exactly `displayed.count` entries, one per displayed word.
    static func alignWords(displayed: [String], normalized: [String]) -> [[String]] {
        guard !displayed.isEmpty else { return [] }
        var result: [[String]] = []
        var ni = 0
        for di in displayed.indices {
            if ni < normalized.count, matchKey(displayed[di]) == matchKey(normalized[ni]) {
                result.append([normalized[ni]])
                ni += 1
                continue
            }
            if di + 1 < displayed.count {
                let nextKey = matchKey(displayed[di + 1])
                if let anchorOffset = normalized[ni...].firstIndex(where: { matchKey($0) == nextKey }) {
                    let owned = Array(normalized[ni..<anchorOffset])
                    result.append(owned.isEmpty ? [displayed[di]] : owned)
                    ni = anchorOffset
                    continue
                }
            }
            // Last displayed word, or no resync point found downstream —
            // claim whatever normalized words remain.
            let owned = ni < normalized.count ? Array(normalized[ni...]) : [displayed[di]]
            result.append(owned)
            ni = normalized.count
        }
        return result
    }

    /// - Parameters:
    ///   - displayedText: the chunk's actual text (what's rendered/highlighted).
    ///   - normalizedText: `NemoTextNormalizer.normalize(displayedText, language: .english)`.
    ///   - result: the real `synthesizeDetailed` output for this exact chunk.
    ///   - groupCount: phoneme-group count for one normalized word — callers
    ///     should memoize this (`KokoroEngineService.phonemeGroupCount`),
    ///     since real text repeats words heavily.
    static func derive(
        displayedText: String,
        normalizedText: String,
        result: KokoroAneSynthesisResult,
        spaceTokenId: Int32,
        groupCount: (String) -> Int
    ) -> [WordTiming] {
        let displayedTokens = splitPreservingSeparators(displayedText)
        guard !displayedTokens.isEmpty else { return [] }
        let displayed = displayedTokens.map(\.word)
        let normalized = normalizedText.split(whereSeparator: \.isWhitespace).map(String.init)

        let owned = alignWords(displayed: displayed, normalized: normalized)
        var targetCounts = owned.map { words in max(1, words.reduce(0) { $0 + groupCount($1) }) }

        let rawGroups = rawPhonemeGroups(result: result, spaceTokenId: spaceTokenId)

        #if DEBUG
        print(
            "[WordTimingDeriver] \"\(displayedText.prefix(60))\" words=\(displayed.count) "
                + "targetSum=\(targetCounts.reduce(0, +)) rawGroups=\(rawGroups.count) "
                + "(match=\(targetCounts.reduce(0, +) == rawGroups.count))")
        #endif

        // Reconcile: if the isolated per-word counts don't sum to the real
        // group count (a rare divergence between phonemizing a word alone
        // vs. in-context), absorb the difference into the last word rather
        // than dropping frames or crashing — every word still gets a
        // timing, in the right order.
        let diff = rawGroups.count - targetCounts.reduce(0, +)
        if diff != 0, !targetCounts.isEmpty {
            targetCounts[targetCounts.count - 1] = max(1, targetCounts[targetCounts.count - 1] + diff)
        }

        let secondsPerFrame: Double =
            result.acousticFrames > 0
            ? Double(result.samples.count / result.acousticFrames) / Double(result.sampleRate) : 0

        var timings: [WordTiming] = []
        var groupIndex = 0
        for (wordIndex, token) in displayedTokens.enumerated() {
            let count = min(targetCounts[wordIndex], max(0, rawGroups.count - groupIndex))
            guard count > 0, groupIndex < rawGroups.count else {
                // Only reachable if reconciliation still fell short — reuse
                // the previous word's end so playback doesn't stall.
                let start = timings.last?.end ?? 0
                timings.append(
                    WordTiming(
                        word: token.word, precedingSeparator: token.precedingSeparator, start: start,
                        end: start))
                continue
            }
            let span = rawGroups[groupIndex..<(groupIndex + count)]
            let start = Double(span.first!.startFrame) * secondsPerFrame
            let end = Double(span.last!.startFrame + span.last!.frames) * secondsPerFrame
            timings.append(
                WordTiming(
                    word: token.word, precedingSeparator: token.precedingSeparator, start: start, end: end))
            groupIndex += count
        }
        return timings
    }

    /// Splits `text` into words the same way `.split(whereSeparator:
    /// \.isWhitespace)` does, but keeps the actual whitespace run that
    /// preceded each word instead of discarding it — the only way to tell
    /// a paragraph break from a plain space apart once the words are back
    /// on their own. First word's separator is always "".
    static func splitPreservingSeparators(_ text: String) -> [(word: String, precedingSeparator: String)] {
        var result: [(word: String, precedingSeparator: String)] = []
        var wordChars: [Character] = []
        var sepChars: [Character] = []
        var inWord = false

        func flushWord() {
            guard !wordChars.isEmpty else { return }
            result.append((String(wordChars), String(sepChars)))
            wordChars = []
            sepChars = []
        }

        for ch in text {
            if ch.isWhitespace {
                if inWord {
                    flushWord()
                    inWord = false
                }
                sepChars.append(ch)
            } else {
                wordChars.append(ch)
                inWord = true
            }
        }
        flushWord()
        return result
    }

    /// Walks `inputIds` (skipping BOS/EOS) grouping on `spaceTokenId`,
    /// tracking each group's start frame and frame count via
    /// `predictedDurations` — the same real per-token data the vocoder used
    /// to render this chunk's audio.
    private static func rawPhonemeGroups(
        result: KokoroAneSynthesisResult, spaceTokenId: Int32
    ) -> [(startFrame: Int, frames: Int)] {
        var groups: [(startFrame: Int, frames: Int)] = []
        var elapsedFrames = 0
        var groupStart: Int?
        var groupFrames = 0
        for (index, id) in result.inputIds.enumerated() {
            let frames = index < result.predictedDurations.count ? Int(result.predictedDurations[index]) : 0
            defer { elapsedFrames += frames }
            if id == KokoroAneConstants.bosTokenId || id == KokoroAneConstants.eosTokenId { continue }
            if id == spaceTokenId {
                if let start = groupStart { groups.append((start, groupFrames)) }
                groupStart = nil
                groupFrames = 0
            } else {
                if groupStart == nil { groupStart = elapsedFrames }
                groupFrames += frames
            }
        }
        if let start = groupStart { groups.append((start, groupFrames)) }
        return groups
    }
}
