import Foundation

/// One public-domain book from Gutendex, ready for display — the upstream
/// JSON's messier shape (authors array, MIME-keyed formats dict, "Last,
/// First" name order) is fully normalized by `GutendexBookService` before
/// this is ever constructed.
struct TrendingBook: Identifiable, Equatable {
    let id: Int
    let title: String
    let authorName: String
    let coverURL: URL?
    let downloadCount: Int
}
