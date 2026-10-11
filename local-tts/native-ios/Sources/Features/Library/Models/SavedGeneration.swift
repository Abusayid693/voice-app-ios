import Foundation

/// Distinguishes newly persisted imported books from manually entered text.
/// The explicit `.unknown` case keeps pre-shelf project metadata decodable
/// without guessing from optional cover artwork.
///
/// `isShelfBook` is what the Book Shelf and shelf-order allocation filter on,
/// rather than `== .pdf` — an imported book belongs on the shelf whatever
/// format it came from.
enum SavedProjectSource: String, Codable, Equatable, Hashable {
    case pdf
    case epub
    case enteredText
    case unknown

    var isShelfBook: Bool { self == .pdf || self == .epub }
}

/// How one book sits on the Book Shelf — face-out (full cover) or turned to
/// its spine, which is far narrower so more books fit per row. Set per book
/// from the shelf's long-press menu and persisted here alongside the other
/// per-project state (`voiceName`, `lastReadPageIndex`), so the shelf looks
/// the same after relaunch. `.cover` is the default for every existing
/// project, which is why it decodes from a missing key.
enum ShelfDisplayMode: String, Codable, Equatable, Hashable {
    case cover
    case spine
}

/// Lightweight metadata for a saved reading project. Page bodies are stored
/// in separate files and loaded only when that page is opened.
struct SavedGeneration: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let title: String
    let engine: Engine
    var voiceName: String
    let createdAt: Date
    let pageCount: Int
    var lastReadPageIndex: Int = 0
    /// How far into `lastReadPageIndex` the reader got, as an index into that
    /// page's `KokoroTextChunker` chunks — see `ReadingPosition`, including
    /// why `lastReadChunkCount` is stored beside it rather than re-derived.
    var lastReadChunkIndex: Int = 0
    var lastReadChunkCount: Int = 0
    var source: SavedProjectSource = .unknown
    var shelfDisplayMode: ShelfDisplayMode = .cover
    /// PDF shelf position reserved when import begins. Missing for projects
    /// created before inline imports; those retain their legacy newest-first order.
    var shelfOrder: Int?

    init(
        id: UUID,
        title: String,
        engine: Engine,
        voiceName: String,
        createdAt: Date,
        pageCount: Int,
        lastReadPageIndex: Int = 0,
        lastReadChunkIndex: Int = 0,
        lastReadChunkCount: Int = 0,
        source: SavedProjectSource = .unknown,
        shelfDisplayMode: ShelfDisplayMode = .cover,
        shelfOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.voiceName = voiceName
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.lastReadPageIndex = lastReadPageIndex
        self.lastReadChunkIndex = lastReadChunkIndex
        self.lastReadChunkCount = lastReadChunkCount
        self.source = source
        self.shelfDisplayMode = shelfDisplayMode
        self.shelfOrder = shelfOrder
    }


    static let baseDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("SavedGenerationsV2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static var projectsDirectory: URL {
        let directory = baseDirectory.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var indexURL: URL { baseDirectory.appendingPathComponent("index.json") }

    static func projectFileURL(id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    static func projectDirectory(id: UUID) -> URL {
        projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func projectPagesDirectory(id: UUID) -> URL {
        projectDirectory(id: id)
            .appendingPathComponent("pages", isDirectory: true)
    }

    static func coverFileURL(id: UUID) -> URL {
        projectDirectory(id: id).appendingPathComponent("cover.jpg")
    }

    static func existingCoverURL(id: UUID) -> URL? {
        let url = coverFileURL(id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func spineArtworkFileURL(id: UUID) -> URL {
        projectDirectory(id: id).appendingPathComponent("spine-artwork-v1.png")
    }

    static func existingSpineArtworkURL(id: UUID) -> URL? {
        let url = spineArtworkFileURL(id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The project's own copy of the imported document, kept so the reader can
    /// show the original page. The import job also holds a copy, but that
    /// directory is the importer's to delete — a project cannot depend on it.
    static func sourcePDFFileURL(id: UUID) -> URL {
        projectDirectory(id: id).appendingPathComponent("source.pdf")
    }

    /// Nil for typed text, and for PDFs imported before the copy existed —
    /// which is what the reader keys off to hide the original-page control.
    static func existingSourcePDFURL(id: UUID) -> URL? {
        let url = sourcePDFFileURL(id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func pageFileURL(projectID: UUID, index: Int) -> URL {
        projectPagesDirectory(id: projectID)
            .appendingPathComponent(String(format: "%06d.json", index))
    }

    /// An imported EPUB's table of contents, resolved to page indexes. Kept
    /// as its own file rather than a field on this struct, so this model's
    /// hand-written `Codable` — see the landmine documented on `CodingKeys`
    /// below — needs no change at all.
    static func chaptersFileURL(id: UUID) -> URL {
        projectDirectory(id: id).appendingPathComponent("chapters.json")
    }

    static func existingChaptersURL(id: UUID) -> URL? {
        let url = chaptersFileURL(id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var summary: SavedGenerationSummary {
        SavedGenerationSummary(
            id: id, title: title, engine: engine, voiceName: voiceName,
            createdAt: createdAt, pageCount: pageCount, lastReadPageIndex: lastReadPageIndex,
            lastReadChunkIndex: lastReadChunkIndex, lastReadChunkCount: lastReadChunkCount,
            source: source,
            shelfDisplayMode: shelfDisplayMode, shelfOrder: shelfOrder)
    }

}

extension SavedGeneration {
    private enum CodingKeys: String, CodingKey {
        case id, title, engine, voiceName, createdAt, pageCount, lastReadPageIndex, source
        case lastReadChunkIndex, lastReadChunkCount
        case shelfDisplayMode, shelfOrder
    }

    /// Existing V2 projects predate resume position and should continue at
    /// page 1 rather than becoming unreadable when the new field is absent.
    ///
    /// **Every defaulted property must be listed here.** A property left out
    /// silently keeps its default on every read instead of the stored value,
    /// which doesn't fail loudly — it just makes writes look like no-ops.
    /// That's exactly what happened when `shelfDisplayMode` was first added
    /// and missed here: rotating a book to its spine saved fine, but
    /// rotating it back read `.cover`, matched the value being written, and
    /// `updateShelfDisplayMode`'s no-change guard returned early without
    /// writing anything.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        engine = try container.decode(Engine.self, forKey: .engine)
        voiceName = try container.decode(String.self, forKey: .voiceName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        lastReadPageIndex = try container.decodeIfPresent(Int.self, forKey: .lastReadPageIndex) ?? 0
        lastReadChunkIndex =
            try container.decodeIfPresent(Int.self, forKey: .lastReadChunkIndex) ?? 0
        lastReadChunkCount =
            try container.decodeIfPresent(Int.self, forKey: .lastReadChunkCount) ?? 0
        source = try container.decodeIfPresent(SavedProjectSource.self, forKey: .source) ?? .unknown
        shelfDisplayMode =
            try container.decodeIfPresent(ShelfDisplayMode.self, forKey: .shelfDisplayMode) ?? .cover
        shelfOrder = try container.decodeIfPresent(Int.self, forKey: .shelfOrder)
    }
}

struct SavedGenerationSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let engine: Engine
    let voiceName: String
    let createdAt: Date
    let pageCount: Int
    var lastReadPageIndex: Int = 0
    var lastReadChunkIndex: Int = 0
    var lastReadChunkCount: Int = 0
    var source: SavedProjectSource = .unknown
    var shelfDisplayMode: ShelfDisplayMode = .cover
    var shelfOrder: Int?

    init(
        id: UUID,
        title: String,
        engine: Engine,
        voiceName: String,
        createdAt: Date,
        pageCount: Int,
        lastReadPageIndex: Int = 0,
        lastReadChunkIndex: Int = 0,
        lastReadChunkCount: Int = 0,
        source: SavedProjectSource = .unknown,
        shelfDisplayMode: ShelfDisplayMode = .cover,
        shelfOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.voiceName = voiceName
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.lastReadPageIndex = lastReadPageIndex
        self.lastReadChunkIndex = lastReadChunkIndex
        self.lastReadChunkCount = lastReadChunkCount
        self.source = source
        self.shelfDisplayMode = shelfDisplayMode
        self.shelfOrder = shelfOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, engine, voiceName, createdAt, pageCount, lastReadPageIndex, source
        case lastReadChunkIndex, lastReadChunkCount
        case shelfDisplayMode, shelfOrder
    }

    /// Existing indexes did not record an origin. Leave those entries out of
    /// the PDF-only shelf rather than misclassifying manually entered text.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        engine = try container.decode(Engine.self, forKey: .engine)
        voiceName = try container.decode(String.self, forKey: .voiceName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        lastReadPageIndex = try container.decodeIfPresent(Int.self, forKey: .lastReadPageIndex) ?? 0
        lastReadChunkIndex =
            try container.decodeIfPresent(Int.self, forKey: .lastReadChunkIndex) ?? 0
        lastReadChunkCount =
            try container.decodeIfPresent(Int.self, forKey: .lastReadChunkCount) ?? 0
        source = try container.decodeIfPresent(SavedProjectSource.self, forKey: .source) ?? .unknown
        shelfDisplayMode =
            try container.decodeIfPresent(ShelfDisplayMode.self, forKey: .shelfDisplayMode) ?? .cover
        shelfOrder = try container.decodeIfPresent(Int.self, forKey: .shelfOrder)
    }

    /// A continuous, perceptual thickness curve keeps short documents close
    /// to a 5pt pamphlet while allowing long books to approach a 36pt spine.
    /// The square root gives thin books enough visible presence without the
    /// old fixed 14pt base making every small PDF look equally thick.
    var spineWidth: CGFloat {
        Self.spineWidth(forPageCount: pageCount)
    }

    static func spineWidth(forPageCount pageCount: Int) -> CGFloat {
        let minimumWidth: CGFloat = 5
        let maximumWidth: CGFloat = 36
        let maximumPageCount: CGFloat = 900
        let pagesAfterFirst = CGFloat(max(pageCount - 1, 0))
        let normalizedPages = min(pagesAfterFirst / (maximumPageCount - 1), 1)
        return minimumWidth + (maximumWidth - minimumWidth) * sqrt(normalizedPages)
    }

    var pageCountLabel: String {
        "\(pageCount) \(pageCount == 1 ? "page" : "pages")"
    }

    /// A resume position maps the first page to 0% and the last page to 100%.
    /// A single-page project has no observable travel distance, so it remains
    /// at 0% until the app gains a separate completion state.
    ///
    /// The chunk reached within that page carries the fraction between two
    /// page marks, so this creeps while one long page is being read instead
    /// of only stepping at page turns. The final `min` is load-bearing: the
    /// denominator is `pageCount - 1` so that the last page reads 100%, and a
    /// within-page fraction *on* that page would otherwise exceed it.
    var readingProgress: Double {
        guard pageCount > 1 else { return 0 }
        let page = Double(min(max(lastReadPageIndex, 0), pageCount - 1))
        let withinPage =
            lastReadChunkCount > 0
            ? Double(min(max(lastReadChunkIndex, 0), lastReadChunkCount))
                / Double(lastReadChunkCount)
            : 0
        return min((page + withinPage) / Double(pageCount - 1), 1)
    }

    /// Covers are optional: typed text and PDF projects made before cover
    /// thumbnails use the standard engine icon in row UI instead.
    var coverURL: URL? {
        SavedGeneration.existingCoverURL(id: id)
    }

    var spineArtworkURL: URL? {
        SavedGeneration.existingSpineArtworkURL(id: id)
    }
}
