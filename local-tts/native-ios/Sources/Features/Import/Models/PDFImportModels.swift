import CoreGraphics
import Foundation

/// Durable lifecycle for an on-device PDF import. Jobs are intentionally
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
        case .validating: return "Checking PDF"
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

    init(id: UUID = UUID(), sourceFileName: String, engine: Engine, voiceName: String) {
        self.id = id
        self.sourceFileName = sourceFileName
        self.engine = engine
        self.voiceName = voiceName
        self.createdAt = Date()
        self.updatedAt = Date()
        self.phase = .queued
        self.totalPages = 0
        self.completedPages = 0
    }

    var progress: Double {
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

    var sourceURL: URL { directory.appendingPathComponent("source.pdf") }
    /// A small raster of the first physical page, retained during import so
    /// it can be copied beside the final project's independently stored pages.
    var coverURL: URL { directory.appendingPathComponent("cover.jpg") }
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
    let isBold: Bool
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
    let isBold: Bool
    /// Set by `PDFParagraphAssembler` from the same typographic evidence it uses
    /// to break paragraphs, so a title/chapter/lesson heading can be styled in
    /// the reader instead of reading as body text.
    let isHeading: Bool
    /// How much larger than the document's body text this paragraph was, already
    /// clamped. 1 for body text and for a heading set apart only by weight.
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
}

struct PDFProcessingProgress: Sendable {
    let phase: PDFImportPhase
    let totalPages: Int
    let completedPages: Int
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
