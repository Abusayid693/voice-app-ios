import Foundation

/// Substitutes the common HTML named-character entities that real EPUB
/// content documents use freely — `&nbsp;`, `&mdash;`, `&rsquo;` — but strict
/// XML does not recognize.
///
/// EPUB requires every content document to be well-formed XML, which only
/// predefines five entities (`amp`, `lt`, `gt`, `quot`, `apos`); `Foundation`'s
/// `XMLParser` enforces exactly that and throws `undefined entity` on
/// anything else, confirmed against real EPUB markup before this was written.
/// Numeric entities (`&#8212;`, `&#x2014;`) are already valid XML and pass
/// through untouched — only *named* entities beyond the five need handling.
///
/// This table is the ~90 names that actually appear in trade-book EPUBs
/// (Latin-1 accents, typographic punctuation, a handful of symbols) rather
/// than the full 2000-plus HTML5 entity set. A name this table doesn't know
/// is left as-is, which — for a document otherwise well-formed — surfaces as
/// a thrown parse error the caller can catch and degrade from, rather than
/// being silently dropped here.
enum EPUBXHTMLEntities {
    static func substitutingNamedEntities(in xml: String) -> String {
        guard xml.contains("&") else { return xml }
        var result = ""
        result.reserveCapacity(xml.count)
        var scanner = xml.startIndex
        let end = xml.endIndex
        while scanner < end {
            let character = xml[scanner]
            guard character == "&",
                  let semicolon = xml[scanner...].firstIndex(of: ";"),
                  xml.distance(from: scanner, to: semicolon) <= 32
            else {
                result.append(character)
                scanner = xml.index(after: scanner)
                continue
            }
            let name = xml[xml.index(after: scanner)..<semicolon]
            // Leave the five predefined XML entities and any numeric entity
            // for XMLParser itself to resolve.
            if name.hasPrefix("#") || Self.xmlPredefined.contains(String(name)) {
                result.append(contentsOf: xml[scanner...semicolon])
            } else if let replacement = table[String(name)] {
                result.append(replacement)
            } else {
                // Unknown name: pass the literal text through. XMLParser will
                // throw on it, which is the signal this chapter needs to
                // degrade rather than being misread here.
                result.append(contentsOf: xml[scanner...semicolon])
            }
            scanner = xml.index(after: semicolon)
        }
        return result
    }

    private static let xmlPredefined: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    private static let table: [String: String] = [
        "nbsp": "\u{00A0}", "shy": "\u{00AD}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "deg": "\u{00B0}", "plusmn": "\u{00B1}", "times": "\u{00D7}",
        "divide": "\u{00F7}", "sect": "\u{00A7}", "para": "\u{00B6}", "middot": "\u{00B7}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
        "cent": "\u{00A2}", "pound": "\u{00A3}", "yen": "\u{00A5}", "euro": "\u{20AC}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "minus": "\u{2212}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "hellip": "\u{2026}", "bull": "\u{2022}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}", "permil": "\u{2030}",
        "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}",
        "circ": "\u{02C6}", "tilde": "\u{02DC}",
        "OElig": "\u{0152}", "oelig": "\u{0153}", "Scaron": "\u{0160}", "scaron": "\u{0161}",
        "Yuml": "\u{0178}", "szlig": "\u{00DF}", "aelig": "\u{00E6}", "AElig": "\u{00C6}",
        "oslash": "\u{00F8}", "Oslash": "\u{00D8}", "aring": "\u{00E5}", "Aring": "\u{00C5}",
        "agrave": "\u{00E0}", "Agrave": "\u{00C0}", "aacute": "\u{00E1}", "Aacute": "\u{00C1}",
        "acirc": "\u{00E2}", "Acirc": "\u{00C2}", "auml": "\u{00E4}", "Auml": "\u{00C4}",
        "atilde": "\u{00E3}", "Atilde": "\u{00C3}",
        "egrave": "\u{00E8}", "Egrave": "\u{00C8}", "eacute": "\u{00E9}", "Eacute": "\u{00C9}",
        "ecirc": "\u{00EA}", "Ecirc": "\u{00CA}", "euml": "\u{00EB}", "Euml": "\u{00CB}",
        "igrave": "\u{00EC}", "Igrave": "\u{00CC}", "iacute": "\u{00ED}", "Iacute": "\u{00CD}",
        "icirc": "\u{00EE}", "Icirc": "\u{00CE}", "iuml": "\u{00EF}", "Iuml": "\u{00CF}",
        "ograve": "\u{00F2}", "Ograve": "\u{00D2}", "oacute": "\u{00F3}", "Oacute": "\u{00D3}",
        "ocirc": "\u{00F4}", "Ocirc": "\u{00D4}", "ouml": "\u{00F6}", "Ouml": "\u{00D6}",
        "otilde": "\u{00F5}", "Otilde": "\u{00D5}",
        "ugrave": "\u{00F9}", "Ugrave": "\u{00D9}", "uacute": "\u{00FA}", "Uacute": "\u{00DA}",
        "ucirc": "\u{00FB}", "Ucirc": "\u{00DB}", "uuml": "\u{00FC}", "Uuml": "\u{00DC}",
        "ccedil": "\u{00E7}", "Ccedil": "\u{00C7}", "ntilde": "\u{00F1}", "Ntilde": "\u{00D1}",
        "yacute": "\u{00FD}", "Yacute": "\u{00DD}", "yuml": "\u{00FF}",
        "eth": "\u{00F0}", "ETH": "\u{00D0}", "thorn": "\u{00FE}", "THORN": "\u{00DE}",
    ]
}
