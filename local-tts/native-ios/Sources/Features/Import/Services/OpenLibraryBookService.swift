import Foundation

/// Fetches books from OpenLibrary's search API (https://openlibrary.org/dev/docs/api/search).
///
/// `sort=new` is the API's own field, not verified to mean "recently
/// published" in practice — checked directly against live responses and
/// found results with implausible `first_publish_year` values (2098, 2027),
/// which looks like dirty crowd-sourced catalog data rather than an API
/// bug. Treat this as "whatever OpenLibrary's `new` sort returns", not a
/// guaranteed-accurate recency feed.
///
/// That same dirty-data pattern is *why* results are filtered to only
/// those with a cover below: checked directly, `sort=new` on
/// `subject:romance` returns a cover hit rate as low as ~2% (4/200 in one
/// sample) — these look like barely-cataloged stub records, not books
/// missing art by chance. `sort=rating`/`sort=editions`/no sort at all
/// were 100% (50/50) in the same check — if this row's threadbare in
/// practice, that's the fix, not fetching a bigger batch.
final class OpenLibraryBookService {
    private static let baseURL = URL(string: "https://openlibrary.org/search.json")!
    fileprivate static let coverBaseURL = URL(string: "https://covers.openlibrary.org/b/id/")!
    /// How many raw results to request per `limit` requested — `sort=new`'s
    /// cover hit rate is low enough that fetching exactly `limit` and
    /// filtering would return almost nothing most of the time.
    private static let overFetchMultiplier = 10

    /// - Parameter subject: OpenLibrary subject tag, e.g. "romance".
    /// - Parameter limit: desired number of *displayable* (cover-having)
    ///   results — may still return fewer, honestly, rather than padding
    ///   the row with cover-less cards.
    func fetchLatestBooks(subject: String, limit: Int = 20) async throws -> [OpenLibraryBook] {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "subject:\(subject)"),
            URLQueryItem(name: "sort", value: "new"),
            URLQueryItem(name: "limit", value: "\(limit * Self.overFetchMultiplier)"),
        ]
        // Same fail-fast reasoning as GutendexBookService: a "what's new" row
        // that hangs for a minute reads as permanently stuck, not failed.
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenLibrarySearchResponse.self, from: data)
        let withCovers = response.docs
            .map(OpenLibraryBook.init(doc:))
            .filter { $0.coverURL != nil }
        return Array(withCovers.prefix(limit))
    }
}

private struct OpenLibrarySearchResponse: Decodable {
    let docs: [OpenLibraryDoc]
}

private struct OpenLibraryDoc: Decodable {
    let key: String
    let title: String
    // Absent for some works (anonymous/uncredited); a plain array, not
    // "Last, First" the way Gutendex's author names are, so no reordering
    // is needed the way GutendexBookService.displayName does.
    let authorName: [String]?
    let coverID: Int?

    enum CodingKeys: String, CodingKey {
        case key, title
        case authorName = "author_name"
        case coverID = "cover_i"
    }
}

extension OpenLibraryBook {
    fileprivate init(doc: OpenLibraryDoc) {
        id = doc.key
        title = doc.title
        authorName = doc.authorName?.first ?? "Unknown"
        coverURL = doc.coverID.flatMap {
            URL(string: "\($0)-M.jpg", relativeTo: OpenLibraryBookService.coverBaseURL)
        }
    }
}
