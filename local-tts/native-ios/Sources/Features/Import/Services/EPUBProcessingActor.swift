import Foundation
import UIKit

/// Turns one imported EPUB into independently stored reader pages, mirroring
/// `PDFProcessingActor`'s contract exactly: same `process(job:progress:)`
/// shape, same stage-weighted progress, same `PDFImportResult`, so
/// `PDFImportManager` routes to either without caring which it got.
///
/// Two deliberate differences from the PDF actor, both because EPUB is
/// reflowable:
///
/// - **Page count isn't known up front.** A PDF reports `pageCount` before
///   any extraction; an EPUB's pages don't exist until every spine document
///   has been parsed and paged, so the parse phase reports progress against
///   the *spine* count and `totalPages` only becomes real afterwards.
/// - **There's no raw per-page extraction checkpoint.** The PDF actor
///   checkpoints extracted geometry per physical page because PDFKit
///   extraction is the expensive part. Here, unzipping and XML-parsing a
///   whole book is cheap next to writing its page files, so parsing simply
///   re-runs on a resume (deterministically, so it produces identical pages)
///   and only the page writes are skipped when already present.
actor EPUBProcessingActor {
    func process(
        job: PDFImportJob,
        progress: @escaping (PDFProcessingProgress) async -> Void
    ) async throws -> PDFImportResult {
        // `EPUBArchiveError` is already `LocalizedError` with a message naming
        // the actual problem ("unsupported compression method", "not a
        // readable EPUB archive"), and `PDFImportManager` shows
        // `localizedDescription` on the failed shelf card — so it propagates
        // rather than being collapsed into one generic case. Reading an entry
        // later, inside `EPUBPackageReader`, already surfaced these intact;
        // catching them here only made the same failure read differently
        // depending on which call hit it first.
        let archive = try EPUBArchive(contentsOf: job.sourceURL)
        let package = try EPUBPackageReader.read(archive)

        await progress(PDFProcessingProgress(
            phase: .validating, totalPages: 0, completedPages: 0,
            overallProgress: 0.02, coverAvailable: false))
        try Task.checkCancellation()

        // Written before any text work, like the PDF actor's own cover pass:
        // a book that goes on to be rejected still shows recognizable
        // artwork beside its retry/delete controls.
        let coverURL = makeCover(archive: archive, package: package, job: job)
        await progress(PDFProcessingProgress(
            phase: .validating, totalPages: 0, completedPages: 0,
            overallProgress: 0.04, coverAvailable: coverURL != nil))

        let built = await buildPages(
            archive: archive, package: package, progress: progress,
            coverAvailable: coverURL != nil)
        try Task.checkCancellation()
        let pageCount = built.pages.count
        guard pageCount > 0 else { throw EPUBImportError.insufficientText }

        await progress(PDFProcessingProgress(
            phase: .preparingPages, totalPages: pageCount, completedPages: 0,
            overallProgress: 0.50, coverAvailable: coverURL != nil))

        try FileManager.default.createDirectory(
            at: job.readerPagesDirectory, withIntermediateDirectories: true)

        var alphanumericCount = 0
        for page in built.pages {
            try Task.checkCancellation()
            let destination = job.readerPageURL(index: page.index)
            // Same reuse rule as the PDF actor: a checkpoint from an older
            // styling pipeline is rewritten rather than trusted, so a resume
            // across an app update can't leave half the book stale.
            let existing = (try? Data(contentsOf: destination))
                .flatMap { try? JSONDecoder().decode(ReaderPage.self, from: $0) }
            if existing?.index != page.index
                || existing?.formatVersion != ReaderPage.currentFormatVersion
            {
                try JSONEncoder().encode(page).write(to: destination, options: .atomic)
            }
            alphanumericCount += page.text.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
            }
            await progress(PDFProcessingProgress(
                phase: .preparingPages, totalPages: pageCount,
                completedPages: page.index + 1,
                overallProgress: 0.50 + 0.47 * Double(page.index + 1) / Double(pageCount),
                coverAvailable: coverURL != nil))
        }

        // Same bar as the PDF path, for the same reason: a book with almost
        // no extractable text is not readable, however well it parsed.
        guard alphanumericCount >= 500 else { throw EPUBImportError.insufficientText }

        await progress(PDFProcessingProgress(
            phase: .finalizing, totalPages: pageCount, completedPages: pageCount,
            overallProgress: 0.99, coverAvailable: coverURL != nil))

        let chaptersURL = writeChapters(built.chapters, job: job)

        let title = package.metadata.title ?? job.sourceFileName
        let spineArtworkURL: URL?
        if let coverURL {
            spineArtworkURL = await makeSpineArtwork(
                coverURL: coverURL, destination: job.spineArtworkURL,
                title: title, pageCount: pageCount)
        } else {
            spineArtworkURL = nil
        }
        try Task.checkCancellation()

        return PDFImportResult(
            title: title,
            pagesDirectory: job.readerPagesDirectory,
            sourceURL: job.sourceURL,
            pageCount: pageCount,
            coverURL: coverURL,
            spineArtworkURL: spineArtworkURL,
            chaptersURL: chaptersURL)
    }

    // MARK: - Parsing

    private struct BuiltBook {
        var pages: [ReaderPage] = []
        var chapters: [EPUBChapter] = []
    }

    /// One place a chapter boundary begins within a spine document: either
    /// the document's own start (no fragment — the whole-document TOC entry
    /// a one-chapter-per-file book has), or a specific element id a
    /// fragment-bearing entry points at.
    private struct SectionBoundary {
        let blockIndex: Int
        let title: String?
        let depth: Int
    }

    /// Builds every page of the book, chapter by chapter.
    ///
    /// Each spine document is split into *sections* at every TOC entry that
    /// resolves inside it — not just the document boundary — so a book that
    /// crams several chapters, or its entire text, into one XHTML file pages
    /// exactly as if each chapter had its own file. `PageSplitter.split` runs
    /// once per section rather than once for the whole book, which is what
    /// makes a chapter boundary always a page boundary: nothing ever packs
    /// two chapters' tails onto one shared page.
    ///
    /// A document that fails to parse is skipped rather than failing the
    /// import: EPUB requires well-formed XHTML and `EPUBXHTMLEntities`
    /// handles the named entities strict XML rejects, but a single
    /// malformed chapter should cost that chapter, not the book.
    private func buildPages(
        archive: EPUBArchive, package: EPUBPackageReader.Package,
        progress: @escaping (PDFProcessingProgress) async -> Void, coverAvailable: Bool
    ) async -> BuiltBook {
        var built = BuiltBook()
        for (spineIndex, item) in package.spine.enumerated() {
            if Task.isCancelled { return built }
            let parsedDocument = (try? archive.data(at: item.path))
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { try? EPUBContentParser.parse($0) }
                ?? EPUBParsedDocument(blocks: [], anchorBlockIndexByID: [:])

            if !parsedDocument.blocks.isEmpty {
                let boundaries = sections(for: item.path, in: parsedDocument, package: package)
                for (index, boundary) in boundaries.enumerated() {
                    let end = index + 1 < boundaries.count
                        ? boundaries[index + 1].blockIndex : parsedDocument.blocks.count
                    appendPages(
                        blocks: Array(parsedDocument.blocks[boundary.blockIndex..<end]),
                        title: boundary.title, depth: boundary.depth, to: &built)
                }
            }

            await progress(PDFProcessingProgress(
                phase: .extracting, totalPages: 0, completedPages: 0,
                overallProgress: 0.04 + 0.46 * Double(spineIndex + 1)
                    / Double(package.spine.count),
                coverAvailable: coverAvailable))
        }
        return built
    }

    /// Resolves this document's own TOC entries to block-index cut points,
    /// always including index 0 — every document starts its own section
    /// even with no TOC entry pointing at it, matching the PDF path's
    /// page-preserving rule that reading order alone, not a table of
    /// contents, decides where a chapter boundary falls back to a plain
    /// page break.
    ///
    /// An entry whose fragment doesn't resolve — a TOC pointing at an id
    /// this document doesn't actually contain — is dropped rather than
    /// failing the import; the rest of the book pages normally.
    private func sections(
        for path: String, in document: EPUBParsedDocument, package: EPUBPackageReader.Package
    ) -> [SectionBoundary] {
        var byBlockIndex: [Int: (title: String, depth: Int)] = [:]
        for entry in package.tocEntries where entry.path == path {
            let blockIndex: Int
            if let fragment = entry.fragment {
                guard let resolved = document.anchorBlockIndexByID[fragment] else { continue }
                blockIndex = resolved
            } else {
                blockIndex = 0
            }
            if byBlockIndex[blockIndex] == nil {
                byBlockIndex[blockIndex] = (entry.title, entry.depth)
            }
        }
        var cuts = Set(byBlockIndex.keys)
        cuts.insert(0)
        return cuts.sorted().map { index in
            let resolved = byBlockIndex[index]
            return SectionBoundary(blockIndex: index, title: resolved?.title, depth: resolved?.depth ?? 0)
        }
    }

    /// Pages one section (the span from one cut point to the next, or to the
    /// end of the document) and appends the result onto the book's running
    /// total — `PageSplitter` paginates with purely local page indexes, so
    /// every page it returns is rebuilt here with its real position in the
    /// finished book, and `formatVersion` is stamped for the first time:
    /// `PageSplitter.split` deliberately leaves it at the `ReaderPage`
    /// default, since only the caller re-indexing pages onto a book knows
    /// which stamp is current.
    private func appendPages(
        blocks: [EPUBBlock], title: String?, depth: Int, to built: inout BuiltBook
    ) {
        guard !blocks.isEmpty else { return }
        let units = blocks.map {
            PageSplitter.StyledUnit(text: $0.text, style: Self.style(for: $0.kind))
        }
        let localPages = PageSplitter.split(units: units)
        guard !localPages.isEmpty else { return }

        if let title {
            built.chapters.append(EPUBChapter(
                title: title, startPageIndex: built.pages.count, depth: depth))
        }
        for local in localPages {
            built.pages.append(ReaderPage(
                index: built.pages.count, text: local.text, styledRanges: local.styledRanges,
                formatVersion: ReaderPage.currentFormatVersion))
        }
    }

    /// Only headings carry a style. `ReaderTextStyle` models size, weight and
    /// serif/sans class — it has no italic or indent axis — so a quote, list
    /// item or caption has nothing it could faithfully express, and returning
    /// nil keeps them out of `styledRanges` entirely, exactly as
    /// `PDFProcessingActor.isPlainBody` keeps ordinary paragraphs out. Their
    /// structure still survives in the text itself (a list item keeps the
    /// marker `EPUBContentParser` synthesized for it).
    private static func style(for kind: EPUBBlockKind) -> ReaderTextStyle? {
        guard case .heading(let level) = kind else { return nil }
        let scale: Double
        let weight: ReaderFontWeight
        switch level {
        case 1: scale = 1.6; weight = .bold
        case 2: scale = 1.4; weight = .bold
        case 3: scale = 1.25; weight = .semibold
        case 4: scale = 1.15; weight = .semibold
        case 5: scale = 1.08; weight = .medium
        default: scale = 1.0; weight = .semibold
        }
        return ReaderTextStyle(scale: scale, weight: weight, fontClass: nil, isHeading: true)
    }

    // MARK: - Chapters

    /// Best-effort, like the artwork below: a book reads perfectly well
    /// without its table of contents resolved.
    private func writeChapters(_ chapters: [EPUBChapter], job: PDFImportJob) -> URL? {
        guard !chapters.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(chapters),
              (try? data.write(to: job.chaptersURL, options: .atomic)) != nil
        else { return nil }
        return job.chaptersURL
    }

    // MARK: - Artwork

    /// Uses the cover the OPF itself declares, which is better than the PDF
    /// path's rendered first page — it is the real jacket rather than a
    /// raster of page one. Re-encoded to the same bounded 600×900 JPEG the
    /// shelf already expects so both formats store identical artwork.
    private func makeCover(
        archive: EPUBArchive, package: EPUBPackageReader.Package, job: PDFImportJob
    ) -> URL? {
        if FileManager.default.fileExists(atPath: job.coverURL.path) { return job.coverURL }
        guard let coverPath = package.metadata.coverPath,
              let data = try? archive.data(at: coverPath),
              let source = UIImage(data: data)
        else { return nil }

        let coverData: Data? = autoreleasepool {
            let coverSize = CGSize(width: 600, height: 900)
            let rendered = UIGraphicsImageRenderer(size: coverSize).image { _ in
                let scale = max(
                    coverSize.width / source.size.width,
                    coverSize.height / source.size.height)
                let size = CGSize(
                    width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: CGRect(
                    x: (coverSize.width - size.width) / 2,
                    y: (coverSize.height - size.height) / 2,
                    width: size.width, height: size.height))
            }
            return rendered.jpegData(compressionQuality: 0.84)
        }
        guard let coverData, (try? coverData.write(to: job.coverURL, options: .atomic)) != nil
        else { return nil }
        return job.coverURL
    }

    private func makeSpineArtwork(
        coverURL: URL, destination: URL, title: String, pageCount: Int
    ) async -> URL? {
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let coverData = try? Data(contentsOf: coverURL) else { return nil }
        let size = CGSize(
            width: SavedGenerationSummary.spineWidth(forPageCount: pageCount),
            height: SavedProjectSpineRenderer.shelfHeight)
        guard let pngData = await SavedProjectSpineRenderer.pngData(
            coverData: coverData, title: title, size: size)
        else { return nil }
        guard !Task.isCancelled else { return nil }
        guard (try? pngData.write(to: destination, options: .atomic)) != nil else { return nil }
        return destination
    }
}
