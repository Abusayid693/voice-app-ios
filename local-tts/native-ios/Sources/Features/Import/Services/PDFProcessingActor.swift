import Foundation
import PDFKit
import UIKit

/// Serializes PDFKit access, checkpoints extracted geometry per source page,
/// and finalizes exactly one independently stored reader page per PDF page.
actor PDFProcessingActor {
    private let extractor: any PDFTextExtractor
    private let assembler = PDFParagraphAssembler()

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
        let bodyFontSize = documentBodyFontSize(job: job, pageCount: pageCount)
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
                    makeParagraphs(from: $0, excluding: repeated, bodyFontSize: bodyFontSize)
                } ?? []
                readerPage = makeReaderPage(at: pageIndex, from: paragraphs)
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
            title: job.sourceFileName,
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

    /// Drops the lines this page shouldn't read aloud, then hands the rest to
    /// `PDFParagraphAssembler` for the actual layout analysis. Deciding what is
    /// junk stays here; deciding how lines group into paragraphs does not.
    private func makeParagraphs(
        from page: PDFPageContent, excluding repeated: Set<String>, bodyFontSize: Double
    ) -> [PDFParagraph] {
        let kept = page.lines.filter {
            !repeated.contains(lineSignature($0.text))
                && !isPrintedPageNumber($0, pageHeight: page.pageHeight)
        }
        guard !kept.isEmpty else { return [] }
        return assembler.paragraphs(
            from: kept, pageIndex: page.pageIndex, pageWidth: page.pageWidth,
            documentBodyFontSize: bodyFontSize)
    }

    /// One body size for the whole document, so a heading's scale means the same
    /// thing on every page. Measured over the geometry already checkpointed on
    /// disk, the same way `repeatedHeaderFooterLines` works, so this costs a
    /// read rather than another PDFKit pass.
    private func documentBodyFontSize(job: PDFImportJob, pageCount: Int) -> Double {
        var lines: [PDFTextFragment] = []
        for pageIndex in 0..<pageCount {
            guard let page = loadPage(job: job, index: pageIndex) else { continue }
            lines.append(contentsOf: page.lines)
        }
        return assembler.bodyFontSize(across: lines)
    }

    /// Joins the page's paragraphs into one string, recording where the headings
    /// landed. The offsets have to be built here, as the text is assembled — the
    /// styling travels beside `text` rather than inside it, because the reader
    /// locates synthesis chunks by searching for them as literal substrings of
    /// this exact string (and the TTS engine speaks it verbatim).
    private func makeReaderPage(at index: Int, from paragraphs: [PDFParagraph]) -> ReaderPage {
        let separator = "\n\n"
        var text = ""
        var headings: [ReaderStyledRange] = []
        for paragraph in paragraphs where !paragraph.text.isEmpty {
            if !text.isEmpty { text += separator }
            if paragraph.isHeading {
                headings.append(ReaderStyledRange(
                    start: text.count, length: paragraph.text.count,
                    style: ReaderTextStyle(
                        scale: paragraph.fontScale, isBold: paragraph.isBold)))
            }
            text += paragraph.text
        }
        // Paragraph text is already trimmed, so no offset can shift here — but
        // guard the invariant rather than trusting it.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == text else {
            return ReaderPage(index: index, text: trimmed)
        }
        return ReaderPage(index: index, text: text, headings: headings)
    }

    private func isPrintedPageNumber(_ line: PDFTextFragment, pageHeight: Double) -> Bool {
        guard isInHeaderOrFooter(line, pageHeight: pageHeight) else { return false }
        let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(
            of: #"^(page\s+)?[0-9ivxlcdm]+$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

}
