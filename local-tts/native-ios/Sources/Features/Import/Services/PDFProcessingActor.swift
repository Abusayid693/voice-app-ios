import Foundation
import PDFKit
import UIKit

/// Serializes PDFKit access, checkpoints extracted geometry per source page,
/// and finalizes exactly one independently stored reader page per PDF page.
actor PDFProcessingActor {
    private let extractor: any PDFTextExtractor

    init(extractor: any PDFTextExtractor = PDFKitTextExtractor()) {
        self.extractor = extractor
    }

    func process(
        job: PDFImportJob,
        progress: @escaping (PDFProcessingProgress) async -> Void
    ) async throws -> PDFImportResult {
        guard let document = PDFDocument(url: job.sourceURL) else {
            throw PDFImportError.unreadableDocument
        }
        guard !document.isLocked else { throw PDFImportError.lockedDocument }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw PDFImportError.noTextLayer }

        await progress(PDFProcessingProgress(
            phase: .validating, totalPages: pageCount, completedPages: 0))
        try Task.checkCancellation()

        let sampleIndexes = distributedSampleIndexes(pageCount: pageCount, maximum: 10)
        let hasTextLayer = sampleIndexes.contains { index in
            guard let page = document.page(at: index) else { return false }
            return !extractor.extractPage(page, index: index).lines.isEmpty
        }
        guard hasTextLayer else { throw PDFImportError.noTextLayer }

        // This is intentionally best-effort: a malformed thumbnail must not
        // prevent a text-layer PDF from becoming readable. Once present, the
        // image survives retries in the import job until Library copies it
        // into the completed project's own directory.
        let coverURL = makeCoverThumbnail(document: document, job: job)

        try FileManager.default.createDirectory(
            at: job.pagesDirectory, withIntermediateDirectories: true)
        let existingPages = Set((try? FileManager.default.contentsOfDirectory(
            at: job.pagesDirectory, includingPropertiesForKeys: nil))?.compactMap { url in
                Int(url.deletingPathExtension().lastPathComponent)
            } ?? [])

        var completed = min(existingPages.count, pageCount)
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            if !existingPages.contains(pageIndex), let page = document.page(at: pageIndex) {
                let content = extractor.extractPage(page, index: pageIndex)
                let data = try JSONEncoder().encode(content)
                try data.write(to: job.pageURL(index: pageIndex), options: .atomic)
                completed += 1
            }
            await progress(PDFProcessingProgress(
                phase: .extracting, totalPages: pageCount, completedPages: completed))
        }

        await progress(PDFProcessingProgress(
            phase: .preparingPages, totalPages: pageCount, completedPages: 0))
        try Task.checkCancellation()

        let repeated = try repeatedHeaderFooterLines(job: job, pageCount: pageCount)
        try FileManager.default.createDirectory(
            at: job.readerPagesDirectory, withIntermediateDirectories: true)

        var alphanumericCount = 0
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            let readerPage: ReaderPage
            if
                let data = try? Data(contentsOf: job.readerPageURL(index: pageIndex)),
                let existing = try? JSONDecoder().decode(ReaderPage.self, from: data),
                existing.index == pageIndex
            {
                readerPage = existing
            } else {
                let paragraphs = loadPage(job: job, index: pageIndex).map {
                    makeParagraphs(from: $0, excluding: repeated)
                } ?? []
                let text = paragraphs.map(\.text).joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                readerPage = ReaderPage(index: pageIndex, text: text)
                let data = try JSONEncoder().encode(readerPage)
                try data.write(to: job.readerPageURL(index: pageIndex), options: .atomic)
            }
            alphanumericCount += readerPage.text.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
            }
            await progress(PDFProcessingProgress(
                phase: .preparingPages, totalPages: pageCount,
                completedPages: pageIndex + 1))
        }

        guard alphanumericCount >= 500 else { throw PDFImportError.insufficientText }
        await progress(PDFProcessingProgress(
            phase: .finalizing, totalPages: pageCount, completedPages: pageCount))
        return PDFImportResult(
            title: job.sourceFileName.replacingOccurrences(
                of: ".pdf", with: "", options: [.caseInsensitive]),
            pagesDirectory: job.readerPagesDirectory,
            pageCount: pageCount,
            coverURL: coverURL)
    }

    /// Uses PDFKit's rendered crop-box image instead of retaining a PDF page
    /// object beyond this actor. The final JPEG is a 600×900 2:3 book-cover
    /// image; pages with another aspect ratio are center-cropped, never
    /// stretched, into that presentation format.
    private func makeCoverThumbnail(document: PDFDocument, job: PDFImportJob) -> URL? {
        if FileManager.default.fileExists(atPath: job.coverURL.path) {
            return job.coverURL
        }
        guard let firstPage = document.page(at: 0) else { return nil }
        let data: Data? = autoreleasepool {
            let coverSize = CGSize(width: 600, height: 900)
            let pageImage = firstPage.thumbnail(
                of: CGSize(width: 1200, height: 1800), for: .cropBox)
            let coverImage = UIGraphicsImageRenderer(size: coverSize).image { _ in
                let scale = max(
                    coverSize.width / pageImage.size.width,
                    coverSize.height / pageImage.size.height)
                let renderedSize = CGSize(
                    width: pageImage.size.width * scale,
                    height: pageImage.size.height * scale)
                pageImage.draw(in: CGRect(
                    x: (coverSize.width - renderedSize.width) / 2,
                    y: (coverSize.height - renderedSize.height) / 2,
                    width: renderedSize.width,
                    height: renderedSize.height))
            }
            return coverImage.jpegData(compressionQuality: 0.84)
        }
        guard let data else { return nil }
        do {
            try data.write(to: job.coverURL, options: .atomic)
            return job.coverURL
        } catch {
            return nil
        }
    }

    private func distributedSampleIndexes(pageCount: Int, maximum: Int) -> [Int] {
        guard pageCount > 1 else { return [0] }
        let count = min(pageCount, maximum)
        return Set((0..<count).map { index in
            Int((Double(index) / Double(max(count - 1, 1))) * Double(pageCount - 1))
        }).sorted()
    }

    private func loadPage(job: PDFImportJob, index: Int) -> PDFPageContent? {
        guard let data = try? Data(contentsOf: job.pageURL(index: index)) else { return nil }
        return try? JSONDecoder().decode(PDFPageContent.self, from: data)
    }

    private func repeatedHeaderFooterLines(
        job: PDFImportJob, pageCount: Int
    ) throws -> Set<String> {
        var counts: [String: Set<Int>] = [:]
        for pageIndex in 0..<pageCount {
            guard let page = loadPage(job: job, index: pageIndex) else { continue }
            for line in page.lines where isInHeaderOrFooter(line, pageHeight: page.pageHeight) {
                let signature = lineSignature(line.text)
                guard signature.count >= 3, !signature.allSatisfy(\.isNumber) else { continue }
                counts[signature, default: []].insert(pageIndex)
            }
        }
        let threshold = max(3, Int(ceil(Double(pageCount) * 0.35)))
        return Set(counts.compactMap { $0.value.count >= threshold ? $0.key : nil })
    }

    private func isInHeaderOrFooter(_ line: PDFTextFragment, pageHeight: Double) -> Bool {
        line.bounds.y <= pageHeight * 0.12 || line.bounds.maxY >= pageHeight * 0.88
    }

    private func lineSignature(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: " ")
    }

    private func makeParagraphs(
        from page: PDFPageContent, excluding repeated: Set<String>
    ) -> [PDFParagraph] {
        let kept = page.lines.filter {
            !repeated.contains(lineSignature($0.text))
                && !isPrintedPageNumber($0, pageHeight: page.pageHeight)
        }
        guard !kept.isEmpty else { return [] }

        var result: [PDFParagraph] = []
        var current: [PDFTextFragment] = []

        func flush() {
            guard let first = current.first else { return }
            let text = join(current)
            if !text.isEmpty {
                result.append(PDFParagraph(
                    text: text, pageIndex: page.pageIndex, top: first.bounds.y,
                    fontSize: first.fontSize, isBold: first.isBold))
            }
            current = []
        }

        for line in kept {
            guard let previous = current.last else {
                current = [line]
                continue
            }
            let verticalGap = line.bounds.y - previous.bounds.maxY
            let differentColumn = abs(line.bounds.x - previous.bounds.x) > max(48, page.pageWidth * 0.12)
            let typographyJump = abs(line.fontSize - previous.fontSize) > 2 || line.isBold != previous.isBold
            if verticalGap > max(7, previous.bounds.height * 1.35) || differentColumn || typographyJump {
                flush()
            }
            current.append(line)
        }
        flush()
        return result
    }

    private func isPrintedPageNumber(_ line: PDFTextFragment, pageHeight: Double) -> Bool {
        guard isInHeaderOrFooter(line, pageHeight: pageHeight) else { return false }
        let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(
            of: #"^(page\s+)?[0-9ivxlcdm]+$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func join(_ lines: [PDFTextFragment]) -> String {
        lines.reduce("") { partial, line in
            guard !partial.isEmpty else { return line.text }
            if partial.hasSuffix("-"), let first = line.text.first, first.isLowercase {
                return String(partial.dropLast()) + line.text
            }
            return partial + " " + line.text
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
