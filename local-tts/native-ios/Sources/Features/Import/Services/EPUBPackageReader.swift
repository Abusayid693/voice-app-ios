import Foundation

/// Reads an EPUB's package structure: `META-INF/container.xml` to find the
/// OPF, the OPF's own metadata/manifest/spine, and the table of contents
/// (EPUB 3 nav document, or an EPUB 2 NCX fallback) resolved against the
/// spine's own paths.
///
/// Every `href` in an EPUB is relative to the document that declares it, not
/// the archive root — the OPF's manifest hrefs are relative to the OPF's own
/// directory, and the nav document's anchor hrefs are relative to *its*
/// directory, which need not be the OPF's. `resolve(href:relativeTo:)` is the
/// one place that distinction is handled, so every call site passes the
/// correct base rather than assuming the archive root.
enum EPUBPackageReader {
    struct Package {
        let metadata: EPUBMetadata
        let spine: [EPUBSpineItem]
        /// Every TOC entry, in document order — not reduced to one per path.
        /// A dictionary keyed by path cannot represent a real table of
        /// contents: it can't preserve order, it can't hold more than one
        /// chapter per content document (common when several chapters, or
        /// the whole book, share one XHTML file and are distinguished only
        /// by `#fragment`), and it can't carry nesting depth. This can.
        let tocEntries: [EPUBTOCEntry]
    }

    static func read(_ archive: EPUBArchive) throws -> Package {
        // Checked first and unconditionally, mirroring how PDFProcessingActor
        // checks `isLocked` before any extraction work: a DRM'd book has no
        // readable content regardless of what the rest of parsing would find.
        guard !archive.contains("META-INF/encryption.xml") else {
            throw EPUBImportError.drmProtected
        }

        let opfPath = try readContainerRootfile(archive)
        let opfDirectory = directory(of: opfPath)
        let opfXML = try xmlString(archive, at: opfPath)
        let opf = try OPFDelegate.parse(opfXML)

        let manifestByID = opf.manifestItems
        let spine: [EPUBSpineItem] = opf.spineItemRefs.compactMap { itemRef in
            guard !itemRef.isNonLinear, let item = manifestByID[itemRef.idref] else { return nil }
            return EPUBSpineItem(path: resolve(href: item.href, relativeTo: opfDirectory))
        }
        guard !spine.isEmpty else { throw EPUBImportError.emptySpine }

        let coverPath = resolveCoverPath(opf: opf, manifestByID: manifestByID, opfDirectory: opfDirectory)
        let metadata = EPUBMetadata(title: opf.title, coverPath: coverPath)

        let entries = try readTOCEntries(
            archive: archive, opf: opf, manifestByID: manifestByID, opfDirectory: opfDirectory)

        return Package(metadata: metadata, spine: spine, tocEntries: entries)
    }

    // MARK: - container.xml

    private static func readContainerRootfile(_ archive: EPUBArchive) throws -> String {
        guard archive.contains("META-INF/container.xml") else {
            throw EPUBImportError.missingPackageDocument
        }
        let xml = try xmlString(archive, at: "META-INF/container.xml")
        guard let path = ContainerDelegate.parse(xml) else {
            throw EPUBImportError.missingPackageDocument
        }
        return path
    }

    // MARK: - Cover resolution

    /// EPUB 3 declares the cover as a manifest item's own
    /// `properties="cover-image"`. EPUB 2 instead points `<meta name="cover"
    /// content="some-id">` at a manifest id — checked only when the modern
    /// form is absent, since a book written to the newer spec is otherwise
    /// unaffected by the older convention also being present.
    private static func resolveCoverPath(
        opf: OPFDelegate.Result, manifestByID: [String: OPFDelegate.ManifestItem],
        opfDirectory: String
    ) -> String? {
        if let item = manifestByID.values.first(where: { $0.properties.contains("cover-image") }) {
            return resolve(href: item.href, relativeTo: opfDirectory)
        }
        if let coverID = opf.legacyCoverMetaContent, let item = manifestByID[coverID] {
            return resolve(href: item.href, relativeTo: opfDirectory)
        }
        return nil
    }

    // MARK: - Table of contents

    private static func readTOCEntries(
        archive: EPUBArchive, opf: OPFDelegate.Result,
        manifestByID: [String: OPFDelegate.ManifestItem], opfDirectory: String
    ) throws -> [EPUBTOCEntry] {
        if let navItem = manifestByID.values.first(where: { $0.properties.contains("nav") }) {
            let navPath = resolve(href: navItem.href, relativeTo: opfDirectory)
            guard archive.contains(navPath) else { return [] }
            let navXML = try xmlString(archive, at: navPath)
            let raw = NavDelegate.parse(navXML)
            return resolvedEntries(raw, relativeTo: directory(of: navPath))
        }
        if let ncxID = opf.legacyTOCAttribute, let ncxItem = manifestByID[ncxID] {
            let ncxPath = resolve(href: ncxItem.href, relativeTo: opfDirectory)
            guard archive.contains(ncxPath) else { return [] }
            let ncxXML = try xmlString(archive, at: ncxPath)
            let raw = NCXDelegate.parse(ncxXML)
            return resolvedEntries(raw, relativeTo: directory(of: ncxPath))
        }
        return []
    }

    /// Every raw entry is kept, in document order — unlike the dictionary
    /// this replaced, nothing here collapses two entries that resolve to the
    /// same content document. A book that puts several chapters, or the
    /// whole book, in one XHTML file and distinguishes them only by
    /// `#fragment` depends on that: `EPUBProcessingActor` is what turns a
    /// fragment into a page break, and it needs every entry to do so.
    private static func resolvedEntries(
        _ raw: [(title: String, href: String, depth: Int)], relativeTo base: String
    ) -> [EPUBTOCEntry] {
        raw.map { entry in
            let (path, fragment) = resolveWithFragment(href: entry.href, relativeTo: base)
            return EPUBTOCEntry(title: entry.title, path: path, fragment: fragment, depth: entry.depth)
        }
    }

    // MARK: - Path resolution

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// Resolves an `href` against the directory of the document that
    /// declared it, discarding any `#fragment` — for manifest/spine/cover
    /// hrefs, which never carry one that means anything to this reader.
    static func resolve(href: String, relativeTo base: String) -> String {
        resolveWithFragment(href: href, relativeTo: base).path
    }

    /// Same resolution, but keeping the fragment — for TOC entries, where it
    /// identifies the element a chapter boundary starts at within its
    /// content document rather than being discardable.
    static func resolveWithFragment(href: String, relativeTo base: String) -> (path: String, fragment: String?) {
        var target = href
        var fragment: String?
        if let hash = target.firstIndex(of: "#") {
            let raw = String(target[target.index(after: hash)...])
            fragment = raw.isEmpty ? nil : raw
            target = String(target[target.startIndex..<hash])
        }
        guard !target.hasPrefix("/") else { return (String(target.dropFirst()), fragment) }

        var components = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for segment in target.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(segment))
            }
        }
        return (components.joined(separator: "/"), fragment)
    }

    // MARK: - XML loading

    private static func xmlString(_ archive: EPUBArchive, at path: String) throws -> String {
        let data = try archive.data(at: path)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw EPUBImportError.missingPackageDocument
        }
        return EPUBXHTMLEntities.substitutingNamedEntities(in: raw)
    }
}

// MARK: - container.xml delegate

private final class ContainerDelegate: NSObject, XMLParserDelegate {
    private var rootfilePath: String?

    static func parse(_ xml: String) -> String? {
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.rootfilePath
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        guard rootfilePath == nil, localName(elementName) == "rootfile" else { return }
        rootfilePath = attributeDict["full-path"]
    }
}

// MARK: - OPF delegate

private final class OPFDelegate: NSObject, XMLParserDelegate {
    struct ManifestItem {
        let href: String
        let properties: Set<String>
    }
    struct SpineItemRef {
        let idref: String
        let isNonLinear: Bool
    }
    struct Result {
        var title: String?
        var legacyCoverMetaContent: String?
        var legacyTOCAttribute: String?
        var manifestItems: [String: ManifestItem] = [:]
        var spineItemRefs: [SpineItemRef] = []
    }

    private var result = Result()
    private var elementStack: [String] = []
    private var titleText = ""
    private var capturingTitle = false

    static func parse(_ xml: String) throws -> Result {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse() else { throw EPUBImportError.missingPackageDocument }
        return delegate.result
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let local = localName(elementName)
        elementStack.append(local)

        switch local {
        case "title" where elementStack.dropLast().last == "metadata":
            capturingTitle = true
            titleText = ""
        case "meta":
            if attributeDict["name"] == "cover", let content = attributeDict["content"] {
                result.legacyCoverMetaContent = content
            }
        case "item":
            guard let id = attributeDict["id"], let href = attributeDict["href"] else { break }
            let properties = Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
            result.manifestItems[id] = ManifestItem(href: href, properties: properties)
        case "spine":
            result.legacyTOCAttribute = attributeDict["toc"]
        case "itemref":
            guard let idref = attributeDict["idref"] else { break }
            let isNonLinear = attributeDict["linear"] == "no"
            result.spineItemRefs.append(SpineItemRef(idref: idref, isNonLinear: isNonLinear))
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingTitle { titleText += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if capturingTitle, localName(elementName) == "title" {
            capturingTitle = false
            let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.title = trimmed }
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}

// MARK: - EPUB 3 nav delegate

private final class NavDelegate: NSObject, XMLParserDelegate {
    private var entries: [(title: String, href: String, depth: Int)] = []
    private var elementStack: [String] = []
    /// The nearest open `<a href="...">` while inside a `<nav epub:type="toc">`.
    private var pendingHref: String?
    private var pendingTitle = ""
    private var navDepth = 0
    /// Count of `<ol>` currently open inside the toc `<nav>`. The outermost
    /// one wraps the top-level `<li>`s, so an entry's depth is this count
    /// minus one at the moment its `<a>` opens — by then the `<ol>`
    /// enclosing it has already incremented this.
    private var olDepth = 0

    static func parse(_ xml: String) -> [(title: String, href: String, depth: Int)] {
        let delegate = NavDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let local = localName(elementName)
        elementStack.append(local)
        if local == "nav" {
            let type = attributeDict["epub:type"] ?? attributeDict["type"] ?? ""
            if type.split(separator: " ").contains("toc") { navDepth += 1 }
        } else if navDepth > 0, local == "ol" {
            olDepth += 1
        } else if navDepth > 0, local == "a", let href = attributeDict["href"] {
            pendingHref = href
            pendingTitle = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if pendingHref != nil { pendingTitle += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        if local == "a", let href = pendingHref {
            let trimmed = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                entries.append((title: trimmed, href: href, depth: max(0, olDepth - 1)))
            }
            pendingHref = nil
        } else if navDepth > 0, local == "ol" {
            olDepth -= 1
        } else if local == "nav", navDepth > 0 {
            navDepth -= 1
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}

// MARK: - EPUB 2 NCX delegate

private final class NCXDelegate: NSObject, XMLParserDelegate {
    private var entries: [(title: String, href: String, depth: Int)] = []
    private var inNavLabelText = false
    private var labelText = ""
    private var pendingTitle: String?
    /// Count of `<navPoint>` currently open. By the time `<content>` fires
    /// for one, this has already been incremented for it, so its depth is
    /// this count minus one — 0-based, matching `NavDelegate`'s convention.
    private var navPointDepth = 0

    static func parse(_ xml: String) -> [(title: String, href: String, depth: Int)] {
        let delegate = NCXDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let local = localName(elementName)
        switch local {
        case "navPoint":
            navPointDepth += 1
        case "text":
            inNavLabelText = true
            labelText = ""
        case "content":
            // `<content src="...">` is the sibling of `<navLabel>` inside the
            // same `<navPoint>`; `pendingTitle` carries the label captured
            // just before it.
            if let src = attributeDict["src"], let title = pendingTitle {
                entries.append((title: title, href: src, depth: max(0, navPointDepth - 1)))
                pendingTitle = nil
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inNavLabelText { labelText += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        if local == "text", inNavLabelText {
            inNavLabelText = false
            let trimmed = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pendingTitle = trimmed }
        } else if local == "navPoint" {
            navPointDepth -= 1
        }
    }
}

/// Strips a namespace prefix (`epub:type` → `type`'s element form, `dc:title`
/// → `title`) so parsing doesn't depend on which prefix a given producer
/// happened to bind — `XMLParser`'s own namespace handling is disabled by
/// default, and enabling it buys nothing here since every element name this
/// reader cares about is unambiguous without its namespace.
private func localName(_ qualified: String) -> String {
    guard let colon = qualified.firstIndex(of: ":") else { return qualified }
    return String(qualified[qualified.index(after: colon)...])
}
