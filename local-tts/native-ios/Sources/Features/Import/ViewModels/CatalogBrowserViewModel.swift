import Combine
import Foundation

@MainActor
final class CatalogBrowserViewModel: ObservableObject {
    enum DownloadStatus: Equatable {
        case idle
        case downloading(filename: String, progress: Double)
        case importing(filename: String)
        case success(String)
        case failure(String)

        var isActive: Bool {
            switch self {
            case .downloading, .importing: return true
            case .idle, .success, .failure: return false
            }
        }
    }

    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var downloadStatus: DownloadStatus = .idle
    @Published var message: String?

    let source: CatalogSource
    let service: CatalogBrowserService

    private let onImport: (URL, BookImportFormat) async -> Void
    private var hasStarted = false

    init(
        source: CatalogSource,
        onImport: @escaping (URL, BookImportFormat) async -> Void
    ) {
        self.source = source
        self.onImport = onImport
        service = CatalogBrowserService()
        connectService()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        service.load(source.url)
    }

    func goBack() { service.goBack() }
    func goForward() { service.goForward() }
    func reload() { service.reload() }
    func openExternally() { service.openCurrentPageExternally() }

    func cancelDownload() {
        service.cancelDownload()
        downloadStatus = .idle
    }

    func clearDownloadStatus() {
        guard !downloadStatus.isActive else { return }
        downloadStatus = .idle
    }

    func browserDidDisappear() {
        service.browserDidDisappear()
    }

    private func connectService() {
        service.onLoadingChanged = { [weak self] in self?.isLoading = $0 }
        service.onNavigationChanged = { [weak self] back, forward, url in
            self?.canGoBack = back
            self?.canGoForward = forward
            self?.currentURL = url
        }
        service.onDownloadStarted = { [weak self] filename in
            self?.downloadStatus = .downloading(filename: filename, progress: 0)
        }
        service.onDownloadProgress = { [weak self] progress in
            guard let self,
                  case let .downloading(filename, _) = downloadStatus
            else { return }
            downloadStatus = .downloading(filename: filename, progress: progress)
        }
        service.onDownloadFailed = { [weak self] error in
            self?.downloadStatus = .failure(error)
        }
        service.onMessage = { [weak self] in self?.message = $0 }
        service.onDownloadFinished = { [weak self] book in
            self?.handoff(book)
        }
    }

    private func handoff(_ book: CatalogDownloadedBook) {
        downloadStatus = .importing(filename: book.displayName)
        // Once WebKit has produced the file, retain this handoff even if the
        // user leaves the browser; PDFImportManager copies it before return.
        Task {
            await onImport(book.fileURL, book.format)
            service.removeTemporaryFile(for: book)
            downloadStatus = .success("Added \(book.displayName) to My Shelf")
        }
    }
}
