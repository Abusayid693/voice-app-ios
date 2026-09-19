import Foundation

/// One semantic chapter of a saved text (max ~2000 words — see
/// `ChapterSplitter`), the unit the chapters list shows and Generate/Play
/// act on. A layer above `KokoroTextChunker`'s ~350-character synthesis
/// chunks: one chapter holds many chunks, chunks stay an internal
/// synthesis detail chapters don't expose.
struct Chapter: Codable, Identifiable, Hashable {
    let index: Int
    let title: String
    let text: String

    var id: Int { index }

    /// A short lead-in for a chapter row, since `title` alone ("Chapter 1")
    /// says nothing about the content.
    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: 80)
        return "\(trimmed[..<cutoff])…"
    }
}
