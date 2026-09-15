import Foundation

/// One static "Classic reads" entry — a public-domain title with real,
/// custom-generated cover art bundled locally (no API). Duration ("30 min")
/// and the "Free Demo" label are the same for every entry, so the card
/// renders those as fixed literals rather than modeling fields that never
/// vary — see `ClassicReadBigCard`.
struct ClassicReadItem: Identifiable {
    let id: String
    let title: String
    let authorName: String
    let coverAssetName: String
}
