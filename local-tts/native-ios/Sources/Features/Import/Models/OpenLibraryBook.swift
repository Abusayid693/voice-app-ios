import Foundation

/// One book from OpenLibrary's search API. `id` is OpenLibrary's own work
/// key (`/works/OL21371867W`), not a numeric id; `coverURL` is resolved
/// separately from the search response's `cover_i`, not handed back as a
/// URL directly.
struct OpenLibraryBook: Identifiable, Equatable {
    /// OpenLibrary's work key, e.g. `/works/OL21371867W` — unique, stable,
    /// used as-is rather than parsed down to just the `OL...W` id.
    let id: String
    let title: String
    let authorName: String
    let coverURL: URL?
}
