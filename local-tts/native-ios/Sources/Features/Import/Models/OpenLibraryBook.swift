import Foundation

/// One book from OpenLibrary's search API — a separate type from
/// `TrendingBook` (Gutendex) rather than a shared one, since the two APIs'
/// shapes genuinely differ: OpenLibrary's id is a string work key
/// (`/works/OL21371867W`), not an Int, and its cover is a separate lookup
/// keyed by `cover_i`, not a URL the search response hands back directly.
struct OpenLibraryBook: Identifiable, Equatable {
    /// OpenLibrary's work key, e.g. `/works/OL21371867W` — unique, stable,
    /// used as-is rather than parsed down to just the `OL...W` id.
    let id: String
    let title: String
    let authorName: String
    let coverURL: URL?
}
