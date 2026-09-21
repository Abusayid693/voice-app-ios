import Foundation
import PDFKit

/// Serializes all PDFKit access and writes each extracted page immediately.
/// PDFKit objects never escape this actor; only Codable app-owned values do.
actor PDFProcessingActor {
    private let extractor: any PDFTextExtractor

    init(extractor: any PDFTextExtractor = PDFKitTextExtractor()) {
        self.extractor = extractor
    }

    func process(
        job: PDFImportJob,
        progress: @escaping (PDFProcessingProgress) async -> Void
    ) async throws -> PDFImportResult {
        guard let document = PDFDocument(url: job.sourceURL) else { throw PDFImportError.unreadableDocument }
        guard !document.isLocked else { throw PDFImportError.lockedDocument }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw PDFImportError.noTextLayer }

        await progress(PDFProcessingProgress(phase: .validating, totalPages: pageCount, completedPages: 0))
        try Task.checkCancellation()

        // Scan distributed pages before committing to a long job. A text
        // layer can be sparse, so any useful sample text is enough to start;
        // the final threshold below protects against image-only PDFs.
        let sampleIndexes = distributedSampleIndexes(pageCount: pageCount, maximum: 10)
        let hasTextLayer = sampleIndexes.contains { index in
            guard let page = document.page(at: index) else { return false }
            return !extractor.extractPage(page, index: index).lines.isEmpty
        }
        guard hasTextLayer else { throw PDFImportError.noTextLayer }

        try FileManager.default.createDirectory(at: job.pagesDirectory, withIntermediateDirectories: true)
        let existingPages = Set((try? FileManager.default.contentsOfDirectory(
            at: job.pagesDirectory, includingPropertiesForKeys: nil))?.compactMap { url -> Int? in
                Int(url.deletingPathExtension().lastPathComponent)
            } ?? [])

        var completed = existingPages.count
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            if !existingPages.contains(pageIndex) {
                guard let page = document.page(at: pageIndex) else { continue }
                let content = extractor.extractPage(page, index: pageIndex)
                let data = try JSONEncoder().encode(content)
                try data.write(to: job.pageURL(index: pageIndex), options: .atomic)
                completed += 1
            }
            await progress(PDFProcessingProgress(
                phase: .extracting, totalPages: pageCount, completedPages: completed))
        }

        let outline = extractor.outlineEntries(in: document)
        await progress(PDFProcessingProgress(
            phase: .chaptering, totalPages: pageCount, completedPages: pageCount))
        try Task.checkCancellation()

        let repeated = try repeatedHeaderFooterLines(job: job, pageCount: pageCount)
        var paragraphs: [PDFParagraph] = []
        paragraphs.reserveCapacity(pageCount * 24)
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            guard let content = loadPage(job: job, index: pageIndex) else { continue }
            paragraphs.append(contentsOf: makeParagraphs(from: content, excluding: repeated))
        }

        let alphanumericCount = paragraphs.reduce(0) { partial, paragraph in
            partial + paragraph.text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        }
        guard alphanumericCount >= 500 else { throw PDFImportError.insufficientText }

        let chapters = chapters(from: paragraphs, outline: outline)
        guard !chapters.isEmpty else { throw PDFImportError.noReadableContent }
        await progress(PDFProcessingProgress(
            phase: .finalizing, totalPages: pageCount, completedPages: pageCount))
        return PDFImportResult(
            title: job.sourceFileName.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive]),
            chapters: chapters)
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

    private func repeatedHeaderFooterLines(job: PDFImportJob, pageCount: Int) throws -> Set<String> {
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

    private func makeParagraphs(from page: PDFPageContent, excluding repeated: Set<String>) -> [PDFParagraph] {
        let kept = page.lines.filter { line in
            !repeated.contains(lineSignature(line.text))
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
            let isSeparate = verticalGap > max(7, previous.bounds.height * 1.35)
                || differentColumn || typographyJump
            if isSeparate {
                flush()
            }
            current.append(line)
        }
        flush()
        return result
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

    private func chapters(from paragraphs: [PDFParagraph], outline: [PDFOutlineEntry]) -> [Chapter] {
        if let outlineChapters = chaptersFromOutline(paragraphs: paragraphs, outline: outline), !outlineChapters.isEmpty {
            return outlineChapters
        }
        if let headingChapters = chaptersFromHeadings(paragraphs: paragraphs), !headingChapters.isEmpty {
            return headingChapters
        }
        return ChapterSplitter.split(paragraphs.map(\.text).joined(separator: "\n\n"))
    }

    private func chaptersFromOutline(
        paragraphs: [PDFParagraph], outline: [PDFOutlineEntry]
    ) -> [Chapter]? {
        let valid = outline.filter { $0.pageIndex >= 0 && !$0.title.isEmpty }
        guard valid.count >= 2 else { return nil }
        let grouped = Dictionary(grouping: valid, by: \.depth)
        let candidates = grouped.values.filter { $0.count >= 2 }.map { entries -> (entries: [PDFOutlineEntry], score: Int) in
            let chapterLabels = entries.filter { chapterLabelScore($0.title) > 0 }.count
            return (entries.sorted(by: locationPrecedes), chapterLabels * 4 + entries.count)
        }
        guard let selected = candidates.max(by: { $0.score < $1.score })?.entries else { return nil }

        let boundaries = deDuplicatedMonotonic(selected)
        guard boundaries.count >= 2 else { return nil }
        var result: [(String, [PDFParagraph])] = []

        // Preserve substantive front matter even when an outline begins on
        // the first numbered chapter.
        let first = boundaries[0]
        let frontMatter = paragraphs.filter { location($0) < location(first) }
        if wordCount(frontMatter) >= 80 {
            result.append(("Introduction", frontMatter))
        }

        for index in boundaries.indices {
            let start = boundaries[index]
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : nil
            let content = paragraphs.filter { paragraph in
                location(paragraph) >= location(start) && (end.map { location(paragraph) < location($0) } ?? true)
            }
            if wordCount(content) >= 20 {
                result.append((start.title, content))
            }
        }
        return makeChapters(result)
    }

    private func chaptersFromHeadings(paragraphs: [PDFParagraph]) -> [Chapter]? {
        let bodySize = weightedBodyFontSize(paragraphs)
        let candidates = paragraphs.enumerated().compactMap { index, paragraph -> Int? in
            headingScore(paragraph, bodySize: bodySize) >= 4 ? index : nil
        }
        guard !candidates.isEmpty else { return nil }

        var boundaries: [(index: Int, title: String)] = []
        for index in candidates {
            let title = paragraphs[index].text
            guard boundaries.last?.title.lowercased() != title.lowercased() else { continue }
            let previousIndex = boundaries.last?.index ?? 0
            // A heading inside the first few body words is normally a cover
            // title or contents line, not a useful reader chapter boundary.
            if !boundaries.isEmpty && wordCount(Array(paragraphs[previousIndex..<index])) < 80 { continue }
            boundaries.append((index, title))
        }
        guard !boundaries.isEmpty else { return nil }

        var result: [(String, [PDFParagraph])] = []
        if boundaries[0].index > 0 {
            let frontMatter = Array(paragraphs[..<boundaries[0].index])
            if wordCount(frontMatter) >= 80 { result.append(("Introduction", frontMatter)) }
        }
        for position in boundaries.indices {
            let boundary = boundaries[position]
            let next = position + 1 < boundaries.count ? boundaries[position + 1].index : paragraphs.count
            let contentStart = min(boundary.index + 1, next)
            let content = Array(paragraphs[contentStart..<next])
            if wordCount(content) >= 20 { result.append((boundary.title, content)) }
        }
        return makeChapters(result)
    }

    private func makeChapters(_ segments: [(String, [PDFParagraph])]) -> [Chapter] {
        segments.enumerated().compactMap { index, segment in
            let text = segment.1.map(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Chapter(index: index, title: segment.0, text: text)
        }
    }

    private func weightedBodyFontSize(_ paragraphs: [PDFParagraph]) -> Double {
        var sizes: [Int: Int] = [:]
        for paragraph in paragraphs where paragraph.fontSize > 0 {
            let key = Int((paragraph.fontSize * 2).rounded())
            sizes[key, default: 0] += max(1, paragraph.text.split(whereSeparator: \.isWhitespace).count)
        }
        let size = sizes.max(by: { $0.value < $1.value })?.key ?? 20
        return Double(size) / 2
    }

    private func headingScore(_ paragraph: PDFParagraph, bodySize: Double) -> Int {
        let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 140, text.split(whereSeparator: \.isWhitespace).count <= 16 else { return 0 }
        var score = 0
        if chapterLabelScore(text) > 0 { score += 4 }
        if paragraph.fontSize >= bodySize * 1.22 { score += 2 }
        if paragraph.isBold && paragraph.fontSize >= bodySize * 1.05 { score += 2 }
        if text == text.uppercased(), text.rangeOfCharacter(from: .letters) != nil { score += 1 }
        return score
    }

    private func chapterLabelScore(_ title: String) -> Int {
        let pattern = #"^\s*((chapter|part|book)\s+([\divxlcdm]+)|[\divxlcdm]+\.)"#
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil ? 0 : 1
    }

    private func deDuplicatedMonotonic(_ entries: [PDFOutlineEntry]) -> [PDFOutlineEntry] {
        entries.reduce(into: []) { result, entry in
            guard let previous = result.last else {
                result.append(entry)
                return
            }
            if location(entry) > location(previous), entry.title != previous.title {
                result.append(entry)
            }
        }
    }

    private func locationPrecedes(_ lhs: PDFOutlineEntry, _ rhs: PDFOutlineEntry) -> Bool {
        location(lhs) < location(rhs)
    }

    private func location(_ paragraph: PDFParagraph) -> Double {
        Double(paragraph.pageIndex) * 1_000_000 + paragraph.top
    }

    private func location(_ outline: PDFOutlineEntry) -> Double {
        Double(outline.pageIndex) * 1_000_000 + outline.top
    }

    private func wordCount(_ paragraphs: [PDFParagraph]) -> Int {
        paragraphs.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}
