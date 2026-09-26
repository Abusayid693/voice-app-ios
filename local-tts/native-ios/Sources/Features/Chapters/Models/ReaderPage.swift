import Foundation

/// One user-visible reading page. PDF imports preserve the source PDF's
/// physical page indexes; typed text is split into pages of at most 2,000
/// words before these values are persisted independently on disk.
/// How a heading was styled in the document it came from, expressed relative to
/// that document's own body text rather than in absolute points — so the reader
/// reproduces the source's hierarchy while still honouring the reader's own font
/// size preference.
struct ReaderTextStyle: Codable, Hashable, Sendable {
    /// Multiple of the reader's body point size.
    let scale: Double
    let isBold: Bool
}

/// A styled span of a page's text, located by character offset.
///
/// Offsets rather than markup in the text itself: `ChapterPlayerView` finds each
/// synthesis chunk by searching for it as a literal substring of `ReaderPage.text`
/// (`computeChunkGaps`), and the same string is what the TTS engine speaks — so
/// inline markers would break chunk matching *and* get read aloud.
struct ReaderStyledRange: Codable, Hashable, Sendable {
    /// Character offset (not UTF-16) from the start of the page's text.
    let start: Int
    let length: Int
    let style: ReaderTextStyle

    var end: Int { start + length }
}

struct ReaderPage: Codable, Identifiable, Hashable, Sendable {
    let index: Int
    let text: String
    /// Empty for typed text and for every page saved before headings existed.
    let headings: [ReaderStyledRange]

    var id: Int { index }
    var number: Int { index + 1 }
    var title: String { "Page \(number)" }

    init(index: Int, text: String, headings: [ReaderStyledRange] = []) {
        self.index = index
        self.text = text
        self.headings = headings
    }

    // Hand-written because Swift's synthesized `Decodable` throws
    // `keyNotFound` for a missing key *even when the property has a default* —
    // the default only feeds the memberwise init. Every reader page already on
    // disk predates `headings`, so a synthesized decoder would fail to load
    // every existing book.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        text = try container.decode(String.self, forKey: .text)
        headings = try container.decodeIfPresent(
            [ReaderStyledRange].self, forKey: .headings) ?? []
    }
}

/// The small, display-only representation used by the page picker. It keeps
/// a large project's picker from retaining every page's complete text.
struct ReaderPagePreview: Identifiable, Hashable, Sendable {
    let index: Int
    let excerpt: String
    let isBlank: Bool

    var id: Int { index }
    var number: Int { index + 1 }
}
