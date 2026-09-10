import Foundation

/// Fetches trending public-domain books from Gutendex
/// (https://gutendex.com), Project Gutenberg's REST API — sorted by
/// popularity (`download_count`) and filtered to `copyright: false` so
/// every result really is public domain, not just "old-looking".
///
/// Pagination rides Gutendex's own `next` link rather than the app
/// building page URLs itself — that link already encodes every query
/// param (sort, copyright filter, page number), so a caller only ever
/// needs "the first page" (pass nil) or "whatever came back as `next`
/// last time".
final class GutendexBookService {
    private static let firstPageURL = URL(
        string: "https://gutendex.com/books/?copyright=false&sort=popular")!

    struct Page {
        let books: [TrendingBook]
        let nextPageURL: URL?
    }

    func fetchPopularBooks(url: URL?) async throws -> Page {
        let (data, _) = try await URLSession.shared.data(from: url ?? Self.firstPageURL)
        let response = try JSONDecoder().decode(GutendexResponse.self, from: data)
        let books = response.results.map(TrendingBook.init(gutendex:))
        return Page(books: books, nextPageURL: response.next)
    }
}

private struct GutendexResponse: Decodable {
    let next: URL?
    let results: [GutendexBook]
}

private struct GutendexBook: Decodable {
    let id: Int
    let title: String
    let authors: [GutendexAuthor]
    let formats: [String: String]
    let downloadCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, authors, formats
        case downloadCount = "download_count"
    }
}

private struct GutendexAuthor: Decodable {
    let name: String
}

extension TrendingBook {
    fileprivate init(gutendex book: GutendexBook) {
        id = book.id
        title = book.title
        authorName = book.authors.first.map(Self.displayName(forAuthor:)) ?? "Unknown"
        coverURL = book.formats["image/jpeg"].flatMap(URL.init(string:))
        downloadCount = book.downloadCount
    }

    // Gutendex names are "Last, First" (e.g. "Austen, Jane") — flip to the
    // usual reading order for display.
    private static func displayName(forAuthor author: GutendexAuthor) -> String {
        let parts = author.name.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return author.name }
        return "\(parts[1]) \(parts[0])"
    }
}
