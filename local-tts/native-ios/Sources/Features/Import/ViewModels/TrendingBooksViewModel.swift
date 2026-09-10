import Foundation

/// Backs both the Import home screen's 5-book preview row and the "See
/// all" screen — one shared instance, so scrolling the full list continues
/// paginating from wherever the preview row left off instead of refetching
/// page 1.
@MainActor
final class TrendingBooksViewModel: ObservableObject {
    @Published private(set) var books: [TrendingBook] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    // Surfaced instead of swallowed — a silent failure previously left the
    // preview row's spinner running forever with no way out and no signal
    // of what went wrong (slow/blocked network, decode mismatch, etc.).
    @Published private(set) var loadErrorMessage: String?

    private var nextPageURL: URL?
    private var hasLoadedOnce = false
    private let service: GutendexBookService

    init(service: GutendexBookService = GutendexBookService()) {
        self.service = service
    }

    /// Called from `.task` on first appearance — safe to call repeatedly
    /// (e.g. every time the Import tab's view re-renders) since it only
    /// actually fetches once, unless the first attempt failed (then it
    /// retries — see `hasLoadedOnce`'s reset in `retry()`).
    func loadInitialPageIfNeeded() async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await loadFirstPage()
    }

    /// Explicit retry from the error state's button — re-attempts the
    /// first page even though `hasLoadedOnce` was already set.
    func retry() async {
        await loadFirstPage()
    }

    private func loadFirstPage() async {
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await service.fetchPopularBooks(url: nil)
            books = page.books
            nextPageURL = page.nextPageURL
        } catch {
            loadErrorMessage = Self.message(for: error)
        }
    }

    /// Call from each row's `.onAppear` in the "See all" grid — loads the
    /// next page once the currently-visible item is near the end of what's
    /// already loaded.
    func loadMoreIfNeeded(currentItem book: TrendingBook) async {
        guard let index = books.firstIndex(of: book) else { return }
        let prefetchThreshold = 4
        guard index >= books.count - prefetchThreshold else { return }
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !isLoadingMore, let url = nextPageURL else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchPopularBooks(url: url)
            books.append(contentsOf: page.books)
            nextPageURL = page.nextPageURL
        } catch {
            // Leave nextPageURL as-is so the next scroll-triggered call
            // simply retries the same page — no visible error UI for a
            // mid-scroll page fetch, just try again next time.
        }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection."
            case .timedOut: return "Request timed out."
            default: return "Network error."
            }
        }
        return "Couldn't load trending books."
    }
}
