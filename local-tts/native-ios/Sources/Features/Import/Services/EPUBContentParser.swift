import Foundation

/// Parses one EPUB content document into `[EPUBBlock]` — the step that makes
/// EPUB import categorically simpler than PDF's: `<h1>`–`<h6>`, `<p>`,
/// `<blockquote>`, `<li>` are read straight off the markup instead of being
/// inferred from font size, indent and leading.
enum EPUBContentParser {
    static func parse(_ xhtml: String) throws -> EPUBParsedDocument {
        let sanitized = EPUBXHTMLEntities.substitutingNamedEntities(in: xhtml)
        let delegate = ContentDelegate()
        let parser = XMLParser(data: Data(sanitized.utf8))
        parser.delegate = delegate
        guard parser.parse() else { throw EPUBContentParseError.malformedDocument }
        return EPUBParsedDocument(
            blocks: delegate.blocks, anchorBlockIndexByID: delegate.anchorBlockIndexByID)
    }
}

enum EPUBContentParseError: Error {
    case malformedDocument
}

/// One content document's blocks, plus where each TOC anchor inside it
/// landed — what lets `EPUBProcessingActor` turn a `#fragment` into a page
/// break rather than every chapter boundary needing its own XHTML file.
struct EPUBParsedDocument {
    let blocks: [EPUBBlock]
    /// Element id → index into `blocks` of the block it anchors to. An id
    /// can sit on the block element itself (`<h1 id="s2">`) or on a wrapper
    /// around it (`<div id="s2"><h1>…`), so this maps to whichever block is
    /// emitted *next* after the id was seen, not necessarily the one
    /// carrying it. An id with nothing following it, or one the TOC
    /// references that doesn't exist in this document at all, simply has no
    /// entry — callers treat a missing key as "no section break here".
    let anchorBlockIndexByID: [String: Int]
}

/// One open block-level element, tracked on a stack so nesting (a `<p>`
/// inside a `<blockquote>`, a `<p>` inside an `<li>`) resolves correctly.
/// `tag` is `nil` for the implicit paragraph opened when text appears with
/// no enclosing block tag at all — loosely structured XHTML is rare in
/// practice (every mainstream EPUB tool wraps every paragraph), but silently
/// dropping stray text would be worse than this one safety net.
private struct PendingBlock {
    let tag: String?
    let kind: EPUBBlockKind
    var text: String = ""
    /// Set only for a `.listItem` block, and only until it's actually used —
    /// see `nextListMarker()` and the marker-stealing in `didStartElement`'s
    /// `"p"` branch for why this lives on the block rather than one shared
    /// mutable scalar (a nested list's own markers would otherwise collide
    /// with its parent's).
    var marker: String? = nil
}

/// One open `<ol>`/`<ul>`, tracked so a nested list's numbering is
/// independent of its parent's.
private struct ListContext {
    let isOrdered: Bool
    var nextOrdinal: Int
}

private final class ContentDelegate: NSObject, XMLParserDelegate {
    private(set) var blocks: [EPUBBlock] = []
    private(set) var anchorBlockIndexByID: [String: Int] = [:]
    private var stack: [PendingBlock] = []
    private var listContextStack: [ListContext] = []
    /// Ids seen since the last emitted block, drained onto the next one in
    /// `emit(_:)`. Appended to *after* each branch below has already called
    /// `prepareForNewChildBlock()` — that call can itself emit a block (an
    /// ancestor's leftover text), and an id just read off the element now
    /// opening must never be attributed to content that precedes it.
    private var pendingIDs: [String] = []

    /// Depth-counted rather than name-matched, so content nested arbitrarily
    /// deep inside a skipped element (a `<table>` containing its own nested
    /// tags) is skipped as a unit without this delegate needing to know the
    /// shape of what it's skipping: `skipFloor` records the depth the skipped
    /// element opened at, and everything is ignored until the close that
    /// returns to it.
    private var skipFloor: Int?
    private var elementDepth = 0

    /// `head` covers `<title>`, `<meta>`, `<link>` and any `<style>` nested
    /// inside it — none of it is body content. Caught by a test that wraps
    /// every fixture in a `<head><title>…</title></head>`, exactly like a
    /// real XHTML document: without this, the title text surfaces as a
    /// spurious leading paragraph, flushed the moment the first real block
    /// tag opens.
    private static let skippedTags: Set<String> = ["head", "script", "style", "nav", "table"]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let local = localName(elementName)
        elementDepth += 1

        if skipFloor != nil {
            return
        }
        if Self.skippedTags.contains(local) {
            skipFloor = elementDepth
            return
        }

        if Self.headingTags.contains(local) {
            prepareForNewChildBlock()
            let level = Int(local.dropFirst()) ?? 1
            stack.append(PendingBlock(tag: local, kind: .heading(level: level)))
        } else if local == "blockquote" {
            prepareForNewChildBlock()
            stack.append(PendingBlock(tag: local, kind: .blockQuote))
        } else if local == "li" {
            prepareForNewChildBlock()
            stack.append(PendingBlock(tag: local, kind: .listItem, marker: nextListMarker()))
        } else if local == "figcaption" {
            prepareForNewChildBlock()
            stack.append(PendingBlock(tag: local, kind: .caption))
        } else if local == "p" {
            prepareForNewChildBlock()
            if let index = nearestQuoteOrListAncestorIndex() {
                // A marker belongs to whichever block actually ends up
                // carrying the `<li>`'s text — steal it from the ancestor
                // now, at the moment that ancestor is identified, rather
                // than leaving both blocks able to claim it later.
                let stolenMarker = stack[index].marker
                stack[index].marker = nil
                stack.append(PendingBlock(tag: local, kind: stack[index].kind, marker: stolenMarker))
            } else {
                stack.append(PendingBlock(tag: local, kind: .paragraph))
            }
        } else if local == "br" {
            appendToOpenBlock(" ")
        } else if local == "ol" {
            prepareForNewChildBlock()
            let start = attributeDict["start"].flatMap(Int.init) ?? 1
            listContextStack.append(ListContext(isOrdered: true, nextOrdinal: start))
        } else if local == "ul" {
            prepareForNewChildBlock()
            listContextStack.append(ListContext(isOrdered: false, nextOrdinal: 0))
        }
        // Every other tag (div, section, span, em, strong, a, sup, i, b, …)
        // is transparent: its own open/close affects neither the stack nor
        // skipping, only the plain descent that already happens.

        // Queued after the branch above, not before — see `pendingIDs`'s
        // own doc comment for why the order matters.
        if let id = attributeDict["id"], !id.isEmpty {
            pendingIDs.append(id)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipFloor == nil else { return }
        if stack.isEmpty {
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            stack.append(PendingBlock(tag: nil, kind: .paragraph))
        }
        appendToOpenBlock(string)
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        defer { elementDepth -= 1 }

        if let floor = skipFloor {
            if elementDepth == floor { skipFloor = nil }
            return
        }

        if local == "ol" || local == "ul" {
            if !listContextStack.isEmpty { listContextStack.removeLast() }
            return
        }

        let blockTags: Set<String> = Self.headingTags.union(["blockquote", "li", "figcaption", "p"])
        guard blockTags.contains(local), let top = stack.last, top.tag == local else { return }
        stack.removeLast()
        emit(top)
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        // Every real block tag is guaranteed a matching close by the time a
        // *well-formed* document finishes parsing, so only a top-level
        // implicit paragraph — which has no closing tag to trigger on — can
        // still be sitting open here.
        if let top = stack.last, top.tag == nil {
            stack.removeLast()
            emit(top)
        }
    }

    // MARK: - Helpers

    private func appendToOpenBlock(_ text: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += text
    }

    /// A `<p>` nested inside an open quote or list item inherits that
    /// container's kind rather than reading as plain body text — the common
    /// `<blockquote><p>…</p></blockquote>` pattern would otherwise emit as
    /// an ordinary paragraph with the wrapper around it contributing nothing.
    private func nearestQuoteOrListAncestorIndex() -> Int? {
        for index in stride(from: stack.count - 1, through: 0, by: -1)
        where stack[index].kind == .blockQuote || stack[index].kind == .listItem {
            return index
        }
        return nil
    }

    /// EPUB's `<li>` carries no literal marker text — a renderer generates
    /// "•" or "1." from CSS, so the DOM alone would silently lose an ordered
    /// list's numbering entirely. Decimal only, regardless of any
    /// `list-style-type`: CSS isn't read here, and plain decimal matches
    /// what nearly every list actually renders as by default.
    private func nextListMarker() -> String {
        guard !listContextStack.isEmpty else { return "\u{2022} " }
        let top = listContextStack[listContextStack.count - 1]
        guard top.isOrdered else { return "\u{2022} " }
        let ordinal = top.nextOrdinal
        listContextStack[listContextStack.count - 1].nextOrdinal += 1
        return "\(ordinal). "
    }

    /// Called before any new block is about to be pushed as a child of
    /// whatever is currently open, so that content the parent already
    /// accumulated keeps its natural reading position ahead of the child
    /// rather than being emitted only once the parent itself closes —
    /// which, for an ancestor that closes *after* its new child, would
    /// place the parent's own text *after* everything the child contains.
    ///
    /// Two cases: a top-level implicit paragraph has no closing tag of its
    /// own, so it must be fully closed (popped) now; a real, still-open
    /// block (a `<blockquote>` or `<li>` with text before a nested tag)
    /// stays open, but its already-typed text is emitted and cleared so
    /// its own eventual close emits nothing extra.
    private func prepareForNewChildBlock() {
        guard let top = stack.last else { return }
        if top.tag == nil {
            stack.removeLast()
            emit(top)
        } else if !top.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emit(top)
            stack[stack.count - 1].text = ""
            stack[stack.count - 1].marker = nil
        }
    }

    private func emit(_ pending: PendingBlock) {
        var normalized = Self.normalize(pending.text)
        guard !normalized.isEmpty else { return }
        if pending.kind == .listItem, let marker = pending.marker {
            normalized = marker + normalized
        }
        let index = blocks.count
        blocks.append(EPUBBlock(kind: pending.kind, text: normalized))
        // First occurrence wins on a duplicate id, same convention as
        // `EPUBPackageReader`'s own de-duplication elsewhere.
        for id in pendingIDs where anchorBlockIndexByID[id] == nil {
            anchorBlockIndexByID[id] = index
        }
        pendingIDs.removeAll()
    }

    /// Collapses every whitespace run — including the raw newlines and
    /// indentation a pretty-printed XHTML source is full of, and the `\u{A0}`
    /// non-breaking spaces `&nbsp;` decodes to — into a single plain space,
    /// matching `PDFTextExtractor.normalizedText`'s treatment of the same
    /// characters. A block's own text must never carry a raw newline: that
    /// character is reserved for the `"\n\n"` separator between blocks.
    private static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = true // so leading whitespace is trimmed, not spaced
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}

private func localName(_ qualified: String) -> String {
    guard let colon = qualified.firstIndex(of: ":") else { return qualified }
    return String(qualified[qualified.index(after: colon)...])
}
