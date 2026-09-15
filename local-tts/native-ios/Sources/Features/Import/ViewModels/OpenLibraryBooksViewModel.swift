import Foundation

/// Backs Import's "New in Romance" row — a single fetch, not paginated
/// like `TrendingBooksViewModel` (there's no "See all" for this row yet;
/// add pagination here the same way if one gets built).
@MainActor
final class OpenLibraryBooksViewModel: ObservableObject {
    @Published private(set) var books: [OpenLibraryBook] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadErrorMessage: String?

    private var hasLoadedOnce = false
    private let service: OpenLibraryBookService
    private let subject: String

    init(subject: String = "romance", service: OpenLibraryBookService = OpenLibraryBookService()) {
        self.subject = subject
        self.service = service
    }

    /// Called from `.task` on first appearance — safe to call repeatedly,
    /// same contract as `TrendingBooksViewModel.loadInitialPageIfNeeded`.
    func loadIfNeeded() async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await load()
    }

    func retry() async {
        await load()
    }

    private func load() async {
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }
        do {
            books = try await service.fetchLatestBooks(subject: subject)
        } catch {
            loadErrorMessage = Self.message(for: error)
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
        return "Couldn't load new romance books."
    }
}
