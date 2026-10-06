import Foundation

/// A block-level kind read straight off the source markup — `<h1>`, `<p>`,
/// `<blockquote>`, `<li>` — rather than inferred from geometry. This is the
/// whole reason EPUB import exists alongside the PDF path: the structure a
/// PDF's paragraph assembler has to guess at from font size and indent is
/// explicit here.
enum EPUBBlockKind: Hashable {
    /// 1...6, from `<h1>`...`<h6>`.
    case heading(level: Int)
    case paragraph
    case blockQuote
    case listItem
    case caption
}

/// One block of text from a content document, in document order. Produced by
/// `EPUBContentParser`, consumed immediately by `PageSplitter`'s block
/// overload — never persisted, so it carries no `Codable` conformance.
struct EPUBBlock: Hashable {
    let kind: EPUBBlockKind
    let text: String
}

/// One entry from the OPF `<spine>`: a content document in reading order.
/// `path` is already resolved to an archive-relative path (the OPF's own
/// `href` values are relative to wherever the OPF file itself sits, not the
/// archive root).
struct EPUBSpineItem: Hashable {
    let path: String
}

struct EPUBMetadata {
    let title: String?
    /// Archive-relative path to the cover image, if the OPF declares one —
    /// via a manifest item's `properties="cover-image"` (EPUB 3) or the older
    /// `<meta name="cover" content="...">` pointing at a manifest id.
    let coverPath: String?
}

/// One entry from the EPUB's own table of contents, in document order.
/// Import-time only, like `EPUBBlock` — never persisted; `EPUBProcessingActor`
/// resolves each entry to a page and stores *that* as `EPUBChapter`
/// (`Features/Chapters/Models`), not this.
struct EPUBTOCEntry {
    let title: String
    /// Archive-relative content document, already resolved against whichever
    /// document declared the `href` (the nav doc or the NCX, not necessarily
    /// the OPF's own directory).
    let path: String
    /// The element id after `#`, when the entry points partway into a
    /// document rather than at its start — several chapters, or a whole
    /// book, routinely share one content document and are told apart only
    /// by this.
    let fragment: String?
    /// 0 = top level. From `<ol>` nesting in an EPUB 3 nav document, or
    /// `<navPoint>` nesting in an EPUB 2 NCX.
    let depth: Int
}

/// Failures specific to interpreting an EPUB's *package*. A damaged container
/// throws `EPUBArchiveError` instead, which carries its own more specific
/// message and is deliberately left to propagate.
enum EPUBImportError: LocalizedError {
    case missingPackageDocument
    case drmProtected
    case emptySpine
    case insufficientText

    var errorDescription: String? {
        switch self {
        case .missingPackageDocument:
            return "This EPUB is missing its package document."
        case .drmProtected:
            return "This EPUB is protected and can't be opened."
        case .emptySpine:
            return "This EPUB does not list any readable chapters."
        case .insufficientText:
            return "This EPUB does not contain enough text to create readable pages."
        }
    }
}
