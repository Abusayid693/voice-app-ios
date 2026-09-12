import Foundation

/// One public-domain book ready for display — usually from Gutendex (the
/// upstream JSON's messier shape is fully normalized by
/// `GutendexBookService` before this is ever constructed), but also used
/// for the hand-curated covers in `ImportHomeView.curatedTrendingBooks`.
struct TrendingBook: Identifiable, Equatable {
    let id: Int
    let title: String
    let authorName: String
    let coverURL: URL?
    let downloadCount: Int
    // Set only for the curated entries above — a bundled asset name that
    // takes priority over `coverURL` in `TrendingBookCard`. nil for every
    // real Gutendex result, which only ever has a remote cover.
    var localCoverAssetName: String? = nil
}
