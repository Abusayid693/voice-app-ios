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
            phase: .validating, totalPages: pageCount, completedPages: 0,
            overallProgress: 0.02, coverAvailable: false))
        try Task.checkCancellation()

        // Render the shelf artwork before text validation. A rejected PDF can
        // still keep the recognizable cover beside its retry/delete controls.
        let coverURL = makeCoverThumbnail(document: document, job: job)
        await progress(PDFProcessingProgress(
            phase: .validating, totalPages: pageCount, completedPages: 0,
            overallProgress: 0.04, coverAvailable: coverURL != nil))

        let sampleIndexes = distributedSampleIndexes(pageCount: pageCount, maximum: 10)
        let hasTextLayer = sampleIndexes.contains { index in
            guard let page = document.page(at: index) else { return false }
            return !extractor.extractPage(page, index: index).lines.isEmpty
        }
        guard hasTextLayer else { throw PDFImportError.noTextLayer }

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
                phase: .extracting, totalPages: pageCount, completedPages: completed,
                overallProgress: 0.04 + 0.46 * Double(completed) / Double(pageCount),
                coverAvailable: coverURL != nil))
        }

        await progress(PDFProcessingProgress(
            phase: .preparingPages, totalPages: pageCount, completedPages: 0,
            overallProgress: 0.50, coverAvailable: coverURL != nil))
        try Task.checkCancellation()

        // Typography first: the header/footer pass needs the body size to tell a
        // running head from a genuine recurring heading.
        let typography = documentTypography(job: job, pageCount: pageCount)
        let bodyFontSize = typography.bodyFontSize
        let headerFooter = try headerFooterRules(
            job: job, pageCount: pageCount, bodyFontSize: bodyFontSize)
        let repeated = headerFooter.repeated
        try FileManager.default.createDirectory(
            at: job.readerPagesDirectory, withIntermediateDirectories: true)

        var alphanumericCount = 0
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            let readerPage: ReaderPage
            if
                let data = try? Data(contentsOf: job.readerPageURL(index: pageIndex)),
                let existing = try? JSONDecoder().decode(ReaderPage.self, from: data),
                existing.index == pageIndex,
                // A page checkpointed by an older styling pipeline is re-derived
                // rather than reused, so an import resumed across an app update
                // can't finalize half the book with the old typography.
                existing.formatVersion == ReaderPage.currentFormatVersion
            {
                readerPage = existing
            } else {
                let content = loadPage(job: job, index: pageIndex)
                let paragraphs = content.map {
                    makeParagraphs(
                        from: $0, excluding: repeated, folioOffset: headerFooter.folioOffset,
                        bodyFontSize: bodyFontSize)
                } ?? []
                readerPage = makeReaderPage(
                    at: pageIndex, from: paragraphs,
                    pageSize: CGSize(
                        width: content?.pageWidth ?? 0, height: content?.pageHeight ?? 0),
                    bodyFontClass: typography.bodyFontClass)
                let data = try JSONEncoder().encode(readerPage)
                try data.write(to: job.readerPageURL(index: pageIndex), options: .atomic)
            }
            alphanumericCount += readerPage.text.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
            }
            await progress(PDFProcessingProgress(
                phase: .preparingPages, totalPages: pageCount,
                completedPages: pageIndex + 1,
                overallProgress: 0.50 + 0.47 * Double(pageIndex + 1) / Double(pageCount),
                coverAvailable: coverURL != nil))
        }

        guard alphanumericCount >= 500 else { throw PDFImportError.insufficientText }
        await progress(PDFProcessingProgress(
            phase: .finalizing, totalPages: pageCount, completedPages: pageCount,
            overallProgress: 0.99, coverAvailable: coverURL != nil))
        return PDFImportResult(
            title: job.sourceFileName,
            pagesDirectory: job.readerPagesDirectory,
            sourceURL: job.sourceURL,
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

    /// The two things one pass over the header/footer bands can learn: which
    /// line texts recur there, and what the printed folio's offset from the
    /// physical page index is.
    ///
    /// **Recurrence is counted, not proportion.** A running head is only
    /// document-wide on the side of the spread carrying the *book* title; the
    /// other side usually carries the *chapter* title, which changes at every
    /// chapter and so covers a few pages out of hundreds. Requiring a share of
    /// the whole document could never catch that side, and it is the side that
    /// most annoys a listener, because the chapter title is then read aloud at
    /// the top of every page of the chapter.
    ///
    /// Three pages is enough because the *band* is already doing most of the
    /// work: prose does not repeat a line verbatim at the very top or bottom of
    /// three separate pages. What the low count does risk is deleting a genuine
    /// recurring heading, so a line larger than the document's body text is
    /// never counted — running heads are set at or below body size, while a real
    /// chapter title is set above it.
    ///
    /// The folio keeps a much higher bar (a true majority): it is a single
    /// number applied to every page, so a wrong offset would quietly strip a
    /// real line from a great many pages.
    private func headerFooterRules(
        job: PDFImportJob, pageCount: Int, bodyFontSize: Double
    ) throws -> (repeated: Set<String>, folioOffset: Int?) {
        var counts: [String: Set<Int>] = [:]
        var folioOffsets: [Int: Set<Int>] = [:]
        for pageIndex in 0..<pageCount {
            guard let page = loadPage(job: job, index: pageIndex) else { continue }
            for line in page.lines where isInHeaderOrFooter(line, pageHeight: page.pageHeight) {
                let signature = lineSignature(line.text)
                let isBodySized = bodyFontSize <= 0 || line.fontSize <= bodyFontSize * 1.05
                if signature.count >= 3, !signature.allSatisfy(\.isNumber), isBodySized {
                    counts[signature, default: []].insert(pageIndex)
                }
                for number in integers(in: line.text) {
                    folioOffsets[number - pageIndex, default: []].insert(pageIndex)
                }
            }
        }
        let repeated = Set(counts.compactMap { $0.value.count >= 3 ? $0.key : nil })
        // Front matter numbered in roman numerals, inserted plates and the like
        // all break the run, so this is a majority signal rather than a
        // universal one.
        let folioThreshold = max(3, Int(ceil(Double(pageCount) * 0.35)))
        let folio = folioOffsets.max { $0.value.count < $1.value.count }
        return (repeated, (folio?.value.count ?? 0) >= folioThreshold ? folio?.key : nil)
    }

    /// Whether this line is one of the recurring band lines `headerFooterRules`
    /// collected — tested against the *same* conditions that collected it, not
    /// against its text alone.
    ///
    /// The band and size conditions have to be repeated here or the rule reaches
    /// too far: a chapter's running head and that chapter's own opening title
    /// are the same words, so matching on signature alone deletes the real title
    /// along with the head. What separates them is exactly what separated them
    /// at collection time — the real title is set larger than body text and
    /// sits below the band.
    private func isRepeatedHeaderFooter(
        _ line: PDFTextFragment, page: PDFPageContent, repeated: Set<String>,
        bodyFontSize: Double
    ) -> Bool {
        guard isInHeaderOrFooter(line, pageHeight: page.pageHeight),
              bodyFontSize <= 0 || line.fontSize <= bodyFontSize * 1.05
        else { return false }
        return repeated.contains(lineSignature(line.text))
    }

    private func integers(in text: String) -> [Int] {
        text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
    }

    /// A band line carrying this page's own folio is a running head, whatever
    /// else is on it — which is the point: the chapter title beside it changes
    /// every chapter and is unrecognisable on its own.
    private func isRunningHead(
        _ line: PDFTextFragment, pageIndex: Int, pageHeight: Double, folioOffset: Int?
    ) -> Bool {
        guard let folioOffset, isInHeaderOrFooter(line, pageHeight: pageHeight) else {
            return false
        }
        return integers(in: line.text).contains(pageIndex + folioOffset)
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
        from page: PDFPageContent, excluding repeated: Set<String>, folioOffset: Int?,
        bodyFontSize: Double
    ) -> [PDFParagraph] {
        let kept = page.lines.filter {
            !isRepeatedHeaderFooter($0, page: page, repeated: repeated, bodyFontSize: bodyFontSize)
                && !isPrintedPageNumber($0, pageHeight: page.pageHeight)
                && !isRunningHead(
                    $0, pageIndex: page.pageIndex, pageHeight: page.pageHeight,
                    folioOffset: folioOffset)
        }
        guard !kept.isEmpty else { return [] }
        return assembler.paragraphs(
            from: kept, pageIndex: page.pageIndex, pageWidth: page.pageWidth,
            documentBodyFontSize: bodyFontSize)
    }

    /// One body size and one body face-class for the whole document, so a
    /// paragraph's scale and its "is this a different face?" test mean the same
    /// thing on every page. Measured over the geometry already checkpointed on
    /// disk, the same way `repeatedHeaderFooterLines` works, so this costs a
    /// read rather than another PDFKit pass.
    private func documentTypography(
        job: PDFImportJob, pageCount: Int
    ) -> (bodyFontSize: Double, bodyFontClass: ReaderFontClass) {
        var lines: [PDFTextFragment] = []
        for pageIndex in 0..<pageCount {
            guard let page = loadPage(job: job, index: pageIndex) else { continue }
            lines.append(contentsOf: page.lines)
        }
        return (assembler.bodyFontSize(across: lines), assembler.bodyFontClass(across: lines))
    }

    /// Joins the page's paragraphs into one string, recording where the styled
    /// ones landed. The offsets have to be built here, as the text is assembled — the
    /// styling travels beside `text` rather than inside it, because the reader
    /// locates synthesis chunks by searching for them as literal substrings of
    /// this exact string (and the TTS engine speaks it verbatim).
    private func makeReaderPage(
        at index: Int, from paragraphs: [PDFParagraph], pageSize: CGSize,
        bodyFontClass: ReaderFontClass
    ) -> ReaderPage {
        let separator = "\n\n"
        var text = ""
        var styledRanges: [ReaderStyledRange] = []
        var lineRects: [ReaderTextRect] = []
        let canMapRects = pageSize.width > 0 && pageSize.height > 0

        for paragraph in paragraphs where !paragraph.text.isEmpty {
            if !text.isEmpty { text += separator }
            let base = text.count
            // Styling is recorded per *source line*, not per paragraph. Assembly
            // merges lines the document set differently whenever none of the
            // prose break rules separate them — a bold contents entry and the
            // regular one beneath it both run to the right margin, so they land
            // in one paragraph — and a paragraph-wide style would then spread
            // the first line's weight across every line after it.
            //
            // Recorded for every line the document set apart, not just headings:
            // size, weight and face all carry structure. A face is only worth
            // recording where it contrasts with the document's own body face,
            // since otherwise the reader's chosen font should keep governing.
            //
            // A paragraph whose lines could not be mapped back to its text
            // keeps the old paragraph-wide range: coarser, but better than
            // dropping its styling entirely.
            let spans: [(start: Int, length: Int, style: ReaderTextStyle)]
            if paragraph.lineSpans.isEmpty {
                spans = [(0, paragraph.text.count, ReaderTextStyle(
                    scale: paragraph.fontScale, weight: paragraph.weight,
                    fontClass: paragraph.fontClass == bodyFontClass ? nil : paragraph.fontClass,
                    isHeading: paragraph.isHeading))]
            } else {
                spans = paragraph.lineSpans.map { span in
                    (span.start, span.length, ReaderTextStyle(
                        scale: span.fontScale, weight: span.weight,
                        fontClass: span.fontClass == bodyFontClass ? nil : span.fontClass,
                        isHeading: paragraph.isHeading))
                }
            }
            for span in spans where !isPlainBody(span.style) {
                styledRanges.append(ReaderStyledRange(
                    start: base + span.start, length: span.length, style: span.style))
            }
            if canMapRects {
                // Rebase each line onto the page's text, and express its
                // rectangle as a fraction of the page so the reader can scale
                // it to whatever size it renders the page at.
                for span in paragraph.lineSpans {
                    lineRects.append(ReaderTextRect(
                        start: base + span.start, length: span.length,
                        x: span.bounds.x / pageSize.width,
                        y: span.bounds.y / pageSize.height,
                        width: span.bounds.width / pageSize.width,
                        height: span.bounds.height / pageSize.height))
                }
            }
            text += paragraph.text
        }

        // Paragraph text is already trimmed, so no offset can shift here — but
        // guard the invariant rather than trusting it.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == text else {
            // Still current-version: the offsets are unsafe, not the pipeline,
            // so re-deriving this page on every resume would change nothing.
            return ReaderPage(
                index: index, text: trimmed, formatVersion: ReaderPage.currentFormatVersion)
        }
        return ReaderPage(
            index: index, text: text, styledRanges: styledRanges, lineRects: lineRects,
            formatVersion: ReaderPage.currentFormatVersion)
    }

    /// Nothing the reader would render differently from its own defaults, so
    /// storing a range for it would cost a page-file entry and a lookup to say
    /// "unchanged".
    private func isPlainBody(_ style: ReaderTextStyle) -> Bool {
        !style.isHeading && style.scale == 1 && style.weight == .regular
            && style.fontClass == nil
    }

    private func isPrintedPageNumber(_ line: PDFTextFragment, pageHeight: Double) -> Bool {
        guard isInHeaderOrFooter(line, pageHeight: pageHeight) else { return false }
        let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(
            of: #"^(page\s+)?[0-9ivxlcdm]+$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

}
