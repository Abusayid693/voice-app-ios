import Foundation
import UIKit

/// Puts back the letters a PDF dropped where its font substituted a ligature
/// glyph it had no `ToUnicode` mapping for.
///
/// The glyph itself draws correctly — which is why such a page *looks* right —
/// but it contributes no characters while still occupying its full advance
/// width. PDFKit infers word spacing from advances, so it reports a space where
/// the glyph stood: "officially" arrives as "o cially", "definite" as
/// "de nite", and "fight" as "ght", the inferred space having merged with the
/// real one before it. Nothing downstream can undo that, because the characters
/// are *absent* from the file's text layer rather than mangled — the dictionary
/// is the only route back.
///
/// Every repair is therefore a guess, which is why `PDFProcessingActor` only
/// builds one of these for a document measured as damaged (see
/// `dropsLigatures`). A book whose ligatures survive extraction must never be
/// run through this.
final class LigatureRepairer {
    private let checker = UITextChecker()
    private var isWordCache: [String: Bool] = [:]

    /// The f-ligatures a text font substitutes. These are the only ones that go
    /// missing in practice; `ﬅ`/`ﬆ` are decorative and rare enough that guessing
    /// at them would cost more than it recovers.
    private static let ligatures = ["ffi", "ffl", "ff", "fi", "fl"]

    /// Repairs one extracted line.
    ///
    /// Tokens are whitespace-separated because `normalizedText` has already
    /// collapsed every run to a single space, so rejoining with single spaces
    /// puts the line back exactly as it was apart from the repairs.
    func repaired(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return text }
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if let repair = repair(token: tokens[index], next: next) {
                output.append(repair.text)
                index += repair.tokensConsumed
            } else {
                output.append(tokens[index])
                index += 1
            }
        }
        return output.joined(separator: " ")
    }

    private func repair(token: String, next: String?) -> (text: String, tokensConsumed: Int)? {
        let head = parts(of: token)
        guard !head.core.isEmpty else { return nil }

        // Rejoining is tried before patching a single token, because a word
        // broken in its middle leaves a short left fragment ("o", "de") that the
        // dictionary may well accept on its own — so waiting for the left token
        // to look wrong would miss exactly the cases this exists for.
        if let next, head.suffix.isEmpty {
            let tail = parts(of: next)
            if !tail.core.isEmpty, tail.prefix.isEmpty, !(isWord(head.core) && isWord(tail.core)),
               let joined = onlyWord(Self.ligatures.map { head.core + $0 + tail.core })
            {
                return (head.prefix + joined + tail.suffix, 2)
            }
        }

        guard !isWord(head.core) else { return nil }
        let characters = Array(head.core)
        var candidates: [String] = []
        for ligature in Self.ligatures {
            for position in 0...characters.count {
                candidates.append(
                    String(characters[0..<position]) + ligature + String(characters[position...]))
            }
        }
        guard let patched = onlyWord(candidates) else { return nil }
        return (head.prefix + patched + head.suffix, 1)
    }

    /// The one candidate the dictionary accepts, or nil where none or several
    /// do. Ambiguity is left alone on purpose: a second plausible reading means
    /// there is no evidence for choosing between them, and leaving the text
    /// visibly broken beats silently inventing the wrong word.
    private func onlyWord(_ candidates: [String]) -> String? {
        var accepted: Set<String> = []
        for candidate in candidates where isWord(candidate) {
            accepted.insert(candidate)
            if accepted.count > 1 { return nil }
        }
        return accepted.first
    }

    /// Splits leading and trailing non-letters off a token, so punctuation rides
    /// along untouched. Interior marks stay in the core — "one's" is one word to
    /// the dictionary, not "one" plus a suffix.
    private func parts(of token: String) -> (prefix: String, core: String, suffix: String) {
        let characters = Array(token)
        var start = 0
        while start < characters.count, !characters[start].isLetter { start += 1 }
        var end = characters.count
        while end > start, !characters[end - 1].isLetter { end -= 1 }
        return (
            String(characters[0..<start]),
            String(characters[start..<end]),
            String(characters[end...])
        )
    }

    /// Memoized: a book runs to hundreds of thousands of words but only tens of
    /// thousands of distinct ones, and a damaged token is tested against every
    /// ligature at every position.
    private func isWord(_ value: String) -> Bool {
        if let cached = isWordCache[value] { return cached }
        let range = NSRange(location: 0, length: value.utf16.count)
        let misspelled = checker.rangeOfMisspelledWord(
            in: value, range: range, startingAt: 0, wrap: false, language: "en_US")
        let result = misspelled.location == NSNotFound
        isWordCache[value] = result
        return result
    }
}
