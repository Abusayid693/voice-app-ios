import Foundation

/// One table-of-contents entry, resolved to a *page* once an EPUB has been
/// split into `ReaderPage`s — what lets a chapter title survive paging with
/// no new reader navigation UI, since it's stored data rather than a
/// feature. Lives beside `ReaderPage`, not in `Features/Import`'s own EPUB
/// models, because — unlike those, which are pure import-time intermediates
/// — this is persisted, reader-facing data of exactly the kind `ReaderPage`
/// itself is (see `ReaderTextRect`'s own doc comment on why the reverse
/// dependency, this file depending on an Import model, is avoided here).
struct EPUBChapter: Codable, Hashable {
    let title: String
    let startPageIndex: Int
    /// 0 = top level, from the source TOC's own nesting. The reader shows
    /// only depth-0 entries as section headers in the Pages picker, to keep
    /// that list from turning into a full outline on a book with real
    /// subsection structure — this is still recorded at every depth so that
    /// can change without re-importing.
    let depth: Int

    init(title: String, startPageIndex: Int, depth: Int) {
        self.title = title
        self.startPageIndex = startPageIndex
        self.depth = depth
    }

    // Hand-written for the same reason as `ReaderTextStyle`'s own decoder
    // (`ReaderPage.swift`): synthesized `Decodable` throws `keyNotFound` for
    // a missing key even when the property has a default, so a value
    // written before `depth` existed would otherwise fail to decode rather
    // than default to 0.
    private enum CodingKeys: String, CodingKey {
        case title, startPageIndex, depth
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        startPageIndex = try container.decode(Int.self, forKey: .startPageIndex)
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
    }
}
