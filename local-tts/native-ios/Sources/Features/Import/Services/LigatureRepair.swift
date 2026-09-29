import Foundation
import UIKit

/// Puts back the letters a PDF dropped where its font substituted a ligature
/// glyph (`ﬁ`, `ff`, `ffi`…) it had no `ToUnicode` mapping for.
///
/// The glyph itself draws correctly — which is why such a page *looks* right —
/// but it yields no characters while still occupying its full advance width.
/// PDFKit infers word spacing from advances, so it reports a space where the
/// glyph stood: "officially" arrives as "o cially", "definite" as "de nite",
/// and "fight" as "ght", the inferred space having merged with the real one
/// before it. The characters are *absent* from the file's text layer rather
/// than mangled, so `PDFKitTextExtractor.decomposingLigatures` — which handles
/// the other variant, where the CMap stores U+FB00–FB06 directly — cannot help.
/// The dictionary is the only route back.
///
/// Split in two on purpose. Deciding what a damaged token should read as needs
/// `UITextChecker`, which is `@MainActor`; applying those decisions is pure
/// string work that belongs on whatever actor is assembling pages. So the
/// planner resolves every repair the document needs in one pass, and hands back
/// a `Sendable` plan the import actor applies by lookup alone.
struct LigatureRepairPlan: Sendable {
    /// Damaged token → what it should read as.
    let singles: [String: String]
    /// `"left right"` → the single word those two tokens should have been.
    let joins: [String: String]

    static let empty = LigatureRepairPlan(singles: [:], joins: [:])

    var isEmpty: Bool { singles.isEmpty && joins.isEmpty }

    /// Applies the plan to one extracted line. Pure lookups, no dictionary.
    ///
    /// Tokens are whitespace-separated because `normalizedText` has already
    /// collapsed every run to a single space, so rejoining with single spaces
    /// restores the line exactly apart from the repairs.
    func repaired(_ text: String) -> String {
        guard !isEmpty else { return text }
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return text }
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            let head = LigatureRepairPlan.parts(of: tokens[index])
            if index + 1 < tokens.count, head.suffix.isEmpty {
                let tail = LigatureRepairPlan.parts(of: tokens[index + 1])
                if tail.prefix.isEmpty,
                   let joined = joins[LigatureRepairPlan.joinKey(head.core, tail.core)]
                {
                    output.append(head.prefix + joined + tail.suffix)
                    index += 2
                    continue
                }
            }
            if let single = singles[head.core] {
                output.append(head.prefix + single + head.suffix)
            } else {
                output.append(tokens[index])
            }
            index += 1
        }
        return output.joined(separator: " ")
    }

    static func joinKey(_ left: String, _ right: String) -> String { left + " " + right }

    /// Splits leading and trailing non-letters off a token so punctuation rides
    /// along untouched. Interior marks stay in the core — "one's" is one word to
    /// the dictionary, not "one" plus a suffix.
    static func parts(of token: String) -> (prefix: String, core: String, suffix: String) {
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
}

/// Builds a `LigatureRepairPlan` for one document. `@MainActor` because
/// `UITextChecker` is (`NS_SWIFT_UI_ACTOR` in the SDK header) — resolving every
/// repair up front is what keeps that isolation off the per-page path.
@MainActor
enum LigatureRepairPlanner {
    /// The f-ligatures a text font substitutes. These are the only ones that go
    /// missing in practice; `ﬅ`/`ﬆ` are decorative and rare enough that guessing
    /// at them would cost more than it recovers.
    private static let ligatures = ["ffi", "ffl", "ff", "fi", "fl"]

    static func plan(forLines lines: [String]) async -> LigatureRepairPlan {
        var checked: [String: Bool] = [:]
        let checker = UITextChecker()
        var sinceYield = 0

        func isWord(_ value: String) async -> Bool {
            if let cached = checked[value] { return cached }
            // The dictionary is the slow part and this runs on the main actor;
            // yielding periodically keeps the import's progress UI responsive
            // instead of freezing it for the length of the whole pass.
            sinceYield += 1
            if sinceYield >= 2_000 {
                sinceYield = 0
                await Task.yield()
            }
            let range = NSRange(location: 0, length: value.utf16.count)
            let result = checker.rangeOfMisspelledWord(
                in: value, range: range, startingAt: 0, wrap: false, language: "en_US"
            ).location == NSNotFound
            checked[value] = result
            return result
        }

        /// The one candidate the dictionary accepts, or nil where none or
        /// several do. Ambiguity is left alone on purpose: a second plausible
        /// reading means there is no evidence for choosing between them, and
        /// leaving text visibly broken beats silently inventing the wrong word.
        func onlyWord(_ candidates: [String]) async -> String? {
            var accepted: Set<String> = []
            for candidate in candidates where await isWord(candidate) {
                accepted.insert(candidate)
                if accepted.count > 1 { return nil }
            }
            return accepted.first
        }

        // Tokenize once; the same cores drive both passes below.
        var lineCores: [[String]] = []
        lineCores.reserveCapacity(lines.count)
        for line in lines {
            lineCores.append(line.split(separator: " ").map {
                LigatureRepairPlan.parts(of: String($0)).core
            })
        }

        var singles: [String: String] = [:]
        var joins: [String: String] = [:]
        var attemptedJoin: Set<String> = []

        for cores in lineCores {
            for (index, core) in cores.enumerated() where !core.isEmpty {
                // Rejoining is tried before patching a single token, because a
                // word broken in its middle leaves a short left fragment the
                // dictionary often accepts on its own — "de" is a word, so
                // waiting for the left side to look wrong would never reach
                // "de"+"nite".
                if index + 1 < cores.count {
                    let next = cores[index + 1]
                    let key = LigatureRepairPlan.joinKey(core, next)
                    if !next.isEmpty, !attemptedJoin.contains(key), joins[key] == nil {
                        attemptedJoin.insert(key)
                        // Separate lets: `&&` takes an autoclosure, which cannot
                        // carry an `await` on its right-hand side.
                        let leftIsWord = await isWord(core)
                        let rightIsWord = await isWord(next)
                        if !(leftIsWord && rightIsWord),
                           let joined = await onlyWord(ligatures.map { core + $0 + next })
                        {
                            joins[key] = joined
                        }
                    }
                }
                guard singles[core] == nil, !(await isWord(core)) else { continue }
                let characters = Array(core)
                var candidates: [String] = []
                for ligature in ligatures {
                    for position in 0...characters.count {
                        candidates.append(
                            String(characters[0..<position]) + ligature
                                + String(characters[position...]))
                    }
                }
                if let patched = await onlyWord(candidates) {
                    singles[core] = patched
                }
            }
        }
        return LigatureRepairPlan(singles: singles, joins: joins)
    }
}
