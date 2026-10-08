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
    private var pendingFormat: BookImportFormat?

    override init() {
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

    func browserDidDisappear() {
        webView.stopLoading()
        cancelDownload()
    }

    func removeTemporaryFile(for book: CatalogDownloadedBook) {
        try? FileManager.default.removeItem(at: book.fileURL.deletingLastPathComponent())
    }

    private func updateNavigationState() {
        onNavigationChanged?(webView.canGoBack, webView.canGoForward, webView.url)
    }

    private func attach(_ download: WKDownload) {
        guard activeDownload == nil else {
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
        if !filename.lowercased().hasSuffix(".\(format.sourceFileExtension)") {
            filename += ".\(format.sourceFileExtension)"
        }
        activeDirectory = directory
        return directory.appendingPathComponent(filename)
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

        if activeDownload != nil,
           (navigationAction.shouldPerformDownload
                || format(for: url, mimeType: nil, suggestedFilename: nil) != nil)
        {
            onMessage?("Finish or cancel the current download first.")
            decisionHandler(.cancel)
            return
        }

        if navigationAction.shouldPerformDownload,
           let detected = format(for: url, mimeType: nil, suggestedFilename: nil)
        {
            pendingFormat = detected
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
        if let detected = format(
            for: response.url,
            mimeType: response.mimeType,
            suggestedFilename: response.suggestedFilename)
        {
            guard activeDownload == nil else {
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
        onLoadingChanged?(false)
        updateNavigationState()
        onMessage?(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        onLoadingChanged?(false)
        updateNavigationState()
        onMessage?(error.localizedDescription)
    }
}

extension CatalogBrowserService: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
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
        guard let directory = activeDirectory,
              let fileURL = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil)
                .first,
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
        if (error as NSError).code != NSURLErrorCancelled {
            onDownloadFailed?(error.localizedDescription)
        }
        clearActiveDownload(removingFiles: true)
    }
}
