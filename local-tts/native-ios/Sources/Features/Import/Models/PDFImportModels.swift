import CoreGraphics
import Foundation

/// Which kind of book a job is importing. The surrounding types keep their
/// historical `PDF…` names — the durable job machinery (jobs.json, retry,
/// `BGProcessingTask`, shelf reservation) never touched PDFKit and works
/// unchanged for either format, and renaming it would orphan in-flight jobs
/// plus the background-task identifier declared in `project.yml` and
/// `Info.plist`. Same convention as `Features/Chapters/` and `LibraryTabView`.
enum BookImportFormat: String, Codable, Equatable {
    case pdf
    case epub

    /// Extension for the copy kept inside the job directory. `source.pdf` is
    /// also what `SavedGeneration.existingSourcePDFURL` looks for, which is
    /// what gates the reader's original-page view — so an EPUB deliberately
    /// never produces that filename.
    var sourceFileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .epub: return "epub"
        }
    }

    var projectSource: SavedProjectSource {
        switch self {
        case .pdf: return .pdf
        case .epub: return .epub
        }
    }
}

/// Durable lifecycle for an on-device book import. Jobs are intentionally
/// independent of SwiftUI presentation so they can resume after the user
/// leaves the import screen or the system interrupts processing.
enum PDFImportPhase: String, Codable, Equatable {
    case queued
    case validating
    case extracting
    case preparingPages
    case finalizing
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .validating: return "Checking book"
        case .extracting: return "Reading pages"
        case .preparingPages: return "Preparing pages"
        case .finalizing: return "Saving book"
        case .completed: return "Ready to read"
        case .failed: return "Import failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

struct PDFImportJob: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceFileName: String
    let engine: Engine
    let voiceName: String
    let createdAt: Date
    var updatedAt: Date
    var phase: PDFImportPhase
    var totalPages: Int
    var completedPages: Int
    var errorMessage: String?
    var projectID: UUID?
    /// Stable position reserved when the picker returns. Optional so jobs
    /// created before inline shelf imports remain decodable.
    var shelfOrder: Int?
    /// Stage-weighted progress that never moves backwards across resumes.
    var overallProgress: Double?
    /// Optional for the same reason `shelfOrder` is: synthesized `Decodable`
    /// reads an Optional with `decodeIfPresent`, so every job already in
    /// `jobs.json` from before EPUB support still decodes. Read
    /// `resolvedFormat`, never this directly.
    var format: BookImportFormat?

    /// Jobs written before EPUB support carry no format and are PDFs.
    var resolvedFormat: BookImportFormat { format ?? .pdf }

    init(
        id: UUID = UUID(), sourceFileName: String, engine: Engine, voiceName: String,
        format: BookImportFormat = .pdf, shelfOrder: Int? = nil
    ) {
        self.id = id
        self.sourceFileName = sourceFileName
        self.engine = engine
        self.voiceName = voiceName
        self.createdAt = Date()
        self.updatedAt = Date()
        self.phase = .queued
        self.totalPages = 0
        self.completedPages = 0
        self.shelfOrder = shelfOrder
        self.overallProgress = 0
        self.format = format
    }

    var progress: Double {
        if let overallProgress {
            return min(max(overallProgress, 0), 1)
        }
        guard totalPages > 0 else { return phase == .completed ? 1 : 0 }
        return min(1, Double(completedPages) / Double(totalPages))
    }

    static let baseDirectory: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = applicationSupport.appendingPathComponent("PDFImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static var indexURL: URL { baseDirectory.appendingPathComponent("jobs.json") }

    var directory: URL {
        Self.baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var sourceURL: URL {
        directory.appendingPathComponent("source.\(resolvedFormat.sourceFileExtension)")
    }
    /// A small raster of the first physical page, retained during import so
    /// it can be copied beside the final project's independently stored pages.
    var coverURL: URL { directory.appendingPathComponent("cover.jpg") }
    var spineArtworkURL: URL { directory.appendingPathComponent("spine-artwork-v1.png") }
    /// EPUB table of contents resolved to page indexes. Written only for
    /// formats that have one, and kept out of `SavedGeneration` so that
    /// model's hand-written `Codable` — and its documented landmine about
    /// defaulted properties silently not round-tripping — stays untouched.
    var chaptersURL: URL { directory.appendingPathComponent("chapters.json") }
    var pagesDirectory: URL { directory.appendingPathComponent("pages", isDirectory: true) }
    var readerPagesDirectory: URL {
        directory.appendingPathComponent("reader-pages", isDirectory: true)
    }

    func pageURL(index: Int) -> URL {
        pagesDirectory.appendingPathComponent(String(format: "%06d.json", index))
    }

    func readerPageURL(index: Int) -> URL {
        readerPagesDirectory.appendingPathComponent(String(format: "%06d.json", index))
    }
}

/// A Codable page-space rectangle normalized into a top-left coordinate
/// system. PDFKit's native page coordinates are lower-left based.
struct PDFNormalizedRect: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

struct PDFTextFragment: Codable, Hashable {
    let text: String
    let pageIndex: Int
    let bounds: PDFNormalizedRect
    let fontName: String?
    let fontSize: Double
    let weight: ReaderFontWeight
    let fontClass: ReaderFontClass

    var isBold: Bool { weight.isEmphasised }

    init(
        text: String, pageIndex: Int, bounds: PDFNormalizedRect, fontName: String?,
        fontSize: Double, weight: ReaderFontWeight, fontClass: ReaderFontClass
    ) {
        self.text = text
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.fontName = fontName
        self.fontSize = fontSize
        self.weight = weight
        self.fontClass = fontClass
    }

    // Page geometry is checkpointed to disk mid-import and resumed on relaunch,
    // so fragments written before weight replaced `isBold` have to keep loading.
    private enum CodingKeys: String, CodingKey {
        case text, pageIndex, bounds, fontName, fontSize, weight, fontClass, isBold
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        bounds = try container.decode(PDFNormalizedRect.self, forKey: .bounds)
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        if let stored = try container.decodeIfPresent(ReaderFontWeight.self, forKey: .weight) {
            weight = stored
        } else {
            weight = (try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false)
                ? .bold : .regular
        }
        fontClass = try container.decodeIfPresent(ReaderFontClass.self, forKey: .fontClass)
            ?? .serif
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(bounds, forKey: .bounds)
        try container.encodeIfPresent(fontName, forKey: .fontName)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(weight, forKey: .weight)
        try container.encode(fontClass, forKey: .fontClass)
    }
}

struct PDFPageContent: Codable, Hashable {
    let pageIndex: Int
    let pageWidth: Double
    let pageHeight: Double
    let lines: [PDFTextFragment]
}

struct PDFParagraph: Codable, Hashable {
    let text: String
    let pageIndex: Int
    let top: Double
    let fontSize: Double
    let weight: ReaderFontWeight
    let fontClass: ReaderFontClass
    /// Set by `PDFParagraphAssembler` from the same typographic evidence it uses
    /// to break paragraphs, so a title/chapter/lesson heading can be styled in
    /// the reader instead of reading as body text.
    let isHeading: Bool
    /// This paragraph's size as a multiple of the document's own body size,
    /// already clamped and snapped. 1 for ordinary body text; below 1 for
    /// captions and footnotes the document set smaller.
    let fontScale: Double
    /// Where each source line's text ended up inside `text`, so the reader can
    /// highlight on the original page image. Empty when the paragraph's text
    /// could not be mapped back safely.
    let lineSpans: [PDFParagraphLineSpan]
}

/// One source line's footprint inside its paragraph: the slice of the
/// paragraph's text it contributed, and the rectangle it occupied on the page.
///
/// Offsets are relative to the paragraph, not the page — `PDFProcessingActor`
/// rebases them when it concatenates paragraphs into the reader page.
struct PDFParagraphLineSpan: Codable, Hashable {
    let start: Int
    let length: Int
    let bounds: PDFNormalizedRect
    /// This line's own typography, kept per line rather than per paragraph.
    /// Assembly regularly merges lines the document set differently — a bold
    /// contents entry and the regular one beneath it both reach the right
    /// margin, so none of the prose break rules separate them — and a single
    /// paragraph-wide style would spread the first line's weight over the rest.
    let weight: ReaderFontWeight
    let fontClass: ReaderFontClass
    let fontScale: Double
}

struct PDFImportResult: Sendable {
    let title: String
    let pagesDirectory: URL
    /// The copied source document, so the project can keep its own copy and
    /// show the original page alongside the extracted text.
    let sourceURL: URL
    let pageCount: Int
    /// Optional so a thumbnail rendering failure cannot discard otherwise
    /// readable imported content; callers use the standard project icon then.
    let coverURL: URL?
    /// Pre-rendered shelf spine; optional visual polish like the cover.
    let spineArtworkURL: URL?
    /// Present only for formats carrying a table of contents (EPUB today).
    let chaptersURL: URL?
}

struct PDFProcessingProgress: Sendable {
    let phase: PDFImportPhase
    let totalPages: Int
    let completedPages: Int
    let overallProgress: Double
    let coverAvailable: Bool
}

enum PDFImportError: LocalizedError {
    case unreadableDocument
    case lockedDocument
    case noTextLayer
    case insufficientText
    case noReadableContent

    var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            return "This PDF could not be opened."
        case .lockedDocument:
            return "Password-protected PDFs are not supported yet."
        case .noTextLayer:
            return "This PDF does not contain selectable text. Scanned PDFs are not supported yet."
        case .insufficientText:
            return "This PDF does not contain enough selectable text to create readable pages."
        case .noReadableContent:
            return "No readable content could be extracted from this PDF."
        }
    }
}
