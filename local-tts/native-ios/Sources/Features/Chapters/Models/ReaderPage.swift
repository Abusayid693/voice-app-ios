import Foundation

/// A font's weight, coarse enough to survive being read back out of an embedded
/// PDF font — where the descriptor's own weight trait is frequently absent and
/// the face name is the only honest signal.
enum ReaderFontWeight: String, Codable, Hashable, Sendable {
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    /// Whether this reads as emphasis rather than ordinary text — the one
    /// question paragraph assembly and heading detection ask of a weight.
    var isEmphasised: Bool {
        switch self {
        case .semibold, .bold, .heavy: return true
        case .light, .regular, .medium: return false
        }
    }
}

/// The broad family a face belongs to — not the face itself. PDFs overwhelmingly
/// embed *subset* fonts (`ABCDEF+MinionPro-Regular`) that exist nowhere on the
/// device, so the specific face can rarely be resolved. What does survive is the
/// contrast between one class and another, which is where a document's structure
/// actually reads from.
enum ReaderFontClass: String, Codable, Hashable, Sendable {
    case serif
    case sansSerif
    case monospaced
}

/// How a paragraph was styled in the document it came from, expressed relative
/// to that document's own body text rather than in absolute points — so the
/// reader reproduces the source's hierarchy while still honouring the reader's
/// own font size preference.
struct ReaderTextStyle: Codable, Hashable, Sendable {
    /// Multiple of the reader's body point size. Below 1 for the likes of
    /// captions and footnotes, which the document set smaller than its body.
    let scale: Double
    let weight: ReaderFontWeight
    /// Set only where this paragraph's class differs from the document's own body
    /// class, so the reader's chosen font still governs ordinary text and only a
    /// deliberate contrast — a sans callout in a serif book, a code block —
    /// overrides it.
    let fontClass: ReaderFontClass?
    /// A heading opens a section and earns space above it; emphasised body text
    /// carries the document's weight but stays in the flow. `PDFParagraphAssembler`
    /// deliberately classifies a full-measure bold line as the latter, so the two
    /// have to be told apart here rather than by "has a style at all".
    let isHeading: Bool

    init(
        scale: Double, weight: ReaderFontWeight, fontClass: ReaderFontClass?,
        isHeading: Bool
    ) {
        self.scale = scale
        self.weight = weight
        self.fontClass = fontClass
        self.isHeading = isHeading
    }

    // Hand-written both ways: `isBold` is a legacy key with no matching property,
    // which the synthesized conformance has no way to express.
    private enum CodingKeys: String, CodingKey {
        case scale
        case weight
        case fontClass
        case isHeading
        case isBold
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = try container.decode(Double.self, forKey: .scale)
        if let stored = try container.decodeIfPresent(ReaderFontWeight.self, forKey: .weight) {
            weight = stored
        } else {
            // Ranges written while weight was still a flag.
            weight = (try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false)
                ? .bold : .regular
        }
        fontClass = try container.decodeIfPresent(ReaderFontClass.self, forKey: .fontClass)
        // Every range written before body text was styled was a heading.
        isHeading = try container.decodeIfPresent(Bool.self, forKey: .isHeading) ?? true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scale, forKey: .scale)
        try container.encode(weight, forKey: .weight)
        try container.encodeIfPresent(fontClass, forKey: .fontClass)
        try container.encode(isHeading, forKey: .isHeading)
    }
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

/// Where a run of this page's text sat on the original PDF page, for reading
/// along on the page image itself rather than on the extracted text.
///
/// Coordinates are fractions of the source page's own width and height with a
/// top-left origin, so a view scales them by whatever size it renders the page
/// at and needs no page dimensions of its own.
///
/// Deliberately its own type rather than reusing `PDFNormalizedRect`: that
/// lives in `Features/Import`, and the reader has no business depending on the
/// import pipeline's models.
struct ReaderTextRect: Codable, Hashable, Sendable {
    /// Character offset into `ReaderPage.text`.
    let start: Int
    let length: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var end: Int { start + length }
}

/// One user-visible reading page. PDF imports preserve the source PDF's
/// physical page indexes; typed text is split into pages of at most 2,000
/// words before these values are persisted independently on disk.
struct ReaderPage: Codable, Identifiable, Hashable, Sendable {
    let index: Int
    let text: String
    /// Headings *and* emphasised body paragraphs, in document order. Empty for
    /// typed text and for every page saved before styling existed.
    let styledRanges: [ReaderStyledRange]
    /// One entry per source line, in reading order. Empty for typed text and
    /// for pages imported before this existed — which is what the reader keys
    /// off to decide whether the original-page view is available at all.
    let lineRects: [ReaderTextRect]
    /// Which revision of the styling pipeline produced this page. An import is
    /// resumable from its page files, so a job interrupted across an app update
    /// would otherwise finalize half its pages with the old typography and half
    /// with the new; `PDFProcessingActor` re-derives anything stale instead of
    /// trusting the checkpoint. 0 for typed text, which has no typography to
    /// derive, and for everything written before this existed.
    let formatVersion: Int

    /// Bump whenever a change to extraction or assembly would produce different
    /// styling for the same PDF.
    static let currentFormatVersion = 4

    var id: Int { index }
    var number: Int { index + 1 }
    var title: String { "Page \(number)" }

    init(
        index: Int, text: String, styledRanges: [ReaderStyledRange] = [],
        lineRects: [ReaderTextRect] = [], formatVersion: Int = 0
    ) {
        self.index = index
        self.text = text
        self.styledRanges = styledRanges
        self.lineRects = lineRects
        self.formatVersion = formatVersion
    }

    // `styledRanges` persists under its original `headings` key: renaming it on
    // disk would orphan the styling on every book already imported.
    private enum CodingKeys: String, CodingKey {
        case index
        case text
        case styledRanges = "headings"
        case lineRects
        case formatVersion
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
        styledRanges = try container.decodeIfPresent(
            [ReaderStyledRange].self, forKey: .styledRanges) ?? []
        lineRects = try container.decodeIfPresent(
            [ReaderTextRect].self, forKey: .lineRects) ?? []
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
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
