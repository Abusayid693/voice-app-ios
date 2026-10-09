import Foundation
import UIKit
import WebKit

/// Owns WebKit and its browser-bound downloads. UI state is reported through
/// callbacks and published only by `CatalogBrowserViewModel`.
@MainActor
final class CatalogBrowserService: NSObject {
    let webView: WKWebView

    var onLoadingChanged: ((Bool) -> Void)?
    var onNavigationChanged: ((Bool, Bool, URL?) -> Void)?
    var onDownloadStarted: ((String) -> Void)?
    var onDownloadProgress: ((Double) -> Void)?
    var onDownloadFinished: ((CatalogDownloadedBook) -> Void)?
    var onDownloadFailed: ((String) -> Void)?
    var onMessage: ((String) -> Void)?

    private var activeDownload: WKDownload?
    private var progressObservation: NSKeyValueObservation?
    private var activeDirectory: URL?
    private var activeFileURL: URL?
    private var pendingFormat: BookImportFormat?
    private var acceptsDownloads = true
    private let source: CatalogSource

    init(source: CatalogSource) {
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func openCurrentPageExternally() {
        guard let url = webView.url else { return }
        UIApplication.shared.open(url)
    }

    func cancelDownload() {
        activeDownload?.cancel()
        clearActiveDownload(removingFiles: true)
    }

    func setAcceptsDownloads(_ acceptsDownloads: Bool) {
        self.acceptsDownloads = acceptsDownloads
    }

    func browserDidDisappear() {
        cancelDownload()
    }

    func removeTemporaryFile(for book: CatalogDownloadedBook) {
        try? FileManager.default.removeItem(at: book.fileURL.deletingLastPathComponent())
    }

    private func updateNavigationState() {
        onNavigationChanged?(webView.canGoBack, webView.canGoForward, webView.url)
    }

    private func handleNavigationFailure(_ error: Error) {
        onLoadingChanged?(false)
        updateNavigationState()

        let error = error as NSError
        let wasCancelled = error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled
        let becameDownload = error.domain == "WebKitErrorDomain" && error.code == 102
        guard !wasCancelled, !becameDownload else { return }
        onMessage?(error.localizedDescription)
    }

    private func attach(_ download: WKDownload) {
        guard acceptsDownloads, activeDownload == nil else {
            download.cancel()
            onMessage?("Finish or cancel the current download first.")
            return
        }

        activeDownload = download
        download.delegate = self
        onLoadingChanged?(false)
        updateNavigationState()
        progressObservation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) {
            [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.onDownloadProgress?(progress.fractionCompleted)
            }
        }
    }

    private func clearActiveDownload(removingFiles: Bool) {
        progressObservation = nil
        activeDownload = nil
        pendingFormat = nil
        if removingFiles, let activeDirectory {
            try? FileManager.default.removeItem(at: activeDirectory)
        }
        activeDirectory = nil
        activeFileURL = nil
    }

    private func format(
        for url: URL?, mimeType: String?, suggestedFilename: String?
    ) -> BookImportFormat? {
        let candidates = [suggestedFilename, url?.lastPathComponent]
            .compactMap { $0?.lowercased() }
        if candidates.contains(where: { $0.hasSuffix(".epub") }) { return .epub }
        if candidates.contains(where: { $0.hasSuffix(".pdf") }) { return .pdf }

        switch mimeType?.lowercased() {
        case "application/epub+zip", "application/x-ibooks+zip": return .epub
        case "application/pdf", "application/x-pdf": return .pdf
        default: return nil
        }
    }

    private func destination(
        suggestedFilename: String,
        format: BookImportFormat
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let unsafeCharacters = CharacterSet(charactersIn: "/\\:")
        var filename = suggestedFilename
            .components(separatedBy: unsafeCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        if filename.isEmpty { filename = "Downloaded Book" }
        if filename == "." || filename == ".." { filename = "Downloaded Book" }
        if !filename.lowercased().hasSuffix(".\(format.sourceFileExtension)") {
            filename += ".\(format.sourceFileExtension)"
        }
        activeDirectory = directory
        let fileURL = directory.appendingPathComponent(filename)
        activeFileURL = fileURL
        return fileURL
    }

    private func opensOutsideCatalog(_ url: URL) -> Bool {
        guard !source.isCustom else { return false }

        let sourceHost = normalizedHost(source.url.host)
        let destinationHost = normalizedHost(url.host)
        guard !sourceHost.isEmpty, !destinationHost.isEmpty else { return false }

        let belongsToSource = destinationHost == sourceHost
            || destinationHost.hasSuffix(".\(sourceHost)")
        if !belongsToSource { return true }

        guard source.id == "standard-ebooks" else { return false }
        let path = url.path.lowercased()
        return ["/donate", "/patrons", "/membership", "/checkout"]
            .contains(where: path.contains)
    }

    private func normalizedHost(_ host: String?) -> String {
        guard let host = host?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension CatalogBrowserService: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased()
        if scheme == "http" {
            onMessage?("This catalog link is not secure. Only HTTPS pages are supported.")
            decisionHandler(.cancel)
            return
        }

        if scheme == "about" || scheme == "data" || scheme == "javascript" {
            decisionHandler(.allow)
            return
        }

        if scheme != "https", scheme != "blob" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if scheme == "https", opensOutsideCatalog(url) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if (!acceptsDownloads || activeDownload != nil),
           (navigationAction.shouldPerformDownload
                || format(for: url, mimeType: nil, suggestedFilename: nil) != nil)
        {
            onMessage?("Finish or cancel the current download first.")
            decisionHandler(.cancel)
            return
        }

        if navigationAction.shouldPerformDownload {
            pendingFormat = format(for: url, mimeType: nil, suggestedFilename: nil)
            decisionHandler(.download)
            return
        }

        if let detected = format(for: url, mimeType: nil, suggestedFilename: nil) {
            pendingFormat = detected
            decisionHandler(.download)
            return
        }

        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        if response.url?.scheme?.lowercased() == "http" {
            onMessage?("This catalog response is not secure. Only HTTPS downloads are supported.")
            decisionHandler(.cancel)
            return
        }

        if let detected = format(
            for: response.url,
            mimeType: response.mimeType,
            suggestedFilename: response.suggestedFilename)
        {
            guard acceptsDownloads, activeDownload == nil else {
                onMessage?("Finish or cancel the current download first.")
                decisionHandler(.cancel)
                return
            }
            pendingFormat = detected
            decisionHandler(.download)
            return
        }

        guard navigationResponse.canShowMIMEType else {
            onMessage?("This file type is not supported. Download a PDF or EPUB instead.")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        attach(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        attach(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        onLoadingChanged?(true)
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onLoadingChanged?(false)
        updateNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }
}

extension CatalogBrowserService: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard download === activeDownload else {
            completionHandler(nil)
            return
        }

        guard let detected = pendingFormat ?? format(
            for: response.url,
            mimeType: response.mimeType,
            suggestedFilename: suggestedFilename)
        else {
            onDownloadFailed?("This file type is not supported. Download a PDF or EPUB instead.")
            completionHandler(nil)
            clearActiveDownload(removingFiles: true)
            return
        }

        do {
            let fileURL = try destination(suggestedFilename: suggestedFilename, format: detected)
            pendingFormat = detected
            onDownloadStarted?(fileURL.lastPathComponent)
            completionHandler(fileURL)
        } catch {
            onDownloadFailed?("Could not prepare this download: \(error.localizedDescription)")
            completionHandler(nil)
            clearActiveDownload(removingFiles: true)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === activeDownload else { return }
        guard let fileURL = activeFileURL,
              let detected = pendingFormat
        else {
            onDownloadFailed?("The downloaded file could not be found.")
            clearActiveDownload(removingFiles: true)
            return
        }

        let book = CatalogDownloadedBook(
            fileURL: fileURL,
            format: detected,
            displayName: fileURL.deletingPathExtension().lastPathComponent)
        clearActiveDownload(removingFiles: false)
        onDownloadFinished?(book)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === activeDownload else { return }
        if (error as NSError).code != NSURLErrorCancelled {
            onDownloadFailed?(error.localizedDescription)
        }
        clearActiveDownload(removingFiles: true)
    }
}
