import Foundation

/// Distinguishes newly persisted PDF books from manually entered text. The
/// explicit `.unknown` case keeps pre-shelf project metadata decodable
/// without guessing from optional cover artwork.
enum SavedProjectSource: String, Codable, Equatable, Hashable {
    case pdf
    case enteredText
    case unknown
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
    var source: SavedProjectSource = .unknown

    init(
        id: UUID,
        title: String,
        engine: Engine,
        voiceName: String,
        createdAt: Date,
        pageCount: Int,
        lastReadPageIndex: Int = 0,
        source: SavedProjectSource = .unknown
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.voiceName = voiceName
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.lastReadPageIndex = lastReadPageIndex
        self.source = source
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

    static func pageFileURL(projectID: UUID, index: Int) -> URL {
        projectPagesDirectory(id: projectID)
            .appendingPathComponent(String(format: "%06d.json", index))
    }

    var summary: SavedGenerationSummary {
        SavedGenerationSummary(
            id: id, title: title, engine: engine, voiceName: voiceName,
            createdAt: createdAt, pageCount: pageCount, source: source)
    }

    var audioDirectory: URL {
        Self.baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func pageAudioFileURL(index: Int) -> URL {
        audioDirectory.appendingPathComponent("page_\(index).wav")
    }

    func pageSidecarFileURL(index: Int) -> URL {
        audioDirectory.appendingPathComponent("page_\(index).json")
    }

    func hasGeneratedAudio(pageIndex: Int) -> Bool {
        FileManager.default.fileExists(atPath: pageAudioFileURL(index: pageIndex).path)
    }
}

extension SavedGeneration {
    private enum CodingKeys: String, CodingKey {
        case id, title, engine, voiceName, createdAt, pageCount, lastReadPageIndex, source
    }

    /// Existing V2 projects predate resume position and should continue at
    /// page 1 rather than becoming unreadable when the new field is absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        engine = try container.decode(Engine.self, forKey: .engine)
        voiceName = try container.decode(String.self, forKey: .voiceName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        lastReadPageIndex = try container.decodeIfPresent(Int.self, forKey: .lastReadPageIndex) ?? 0
        source = try container.decodeIfPresent(SavedProjectSource.self, forKey: .source) ?? .unknown
    }
}

struct SavedGenerationSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let engine: Engine
    let voiceName: String
    let createdAt: Date
    let pageCount: Int
    var source: SavedProjectSource = .unknown

    init(
        id: UUID,
        title: String,
        engine: Engine,
        voiceName: String,
        createdAt: Date,
        pageCount: Int,
        source: SavedProjectSource = .unknown
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.voiceName = voiceName
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, engine, voiceName, createdAt, pageCount, source
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
        source = try container.decodeIfPresent(SavedProjectSource.self, forKey: .source) ?? .unknown
    }

    var pageCountLabel: String {
        "\(pageCount) \(pageCount == 1 ? "page" : "pages")"
    }

    /// Covers are optional: typed text and PDF projects made before cover
    /// thumbnails use the standard engine icon in row UI instead.
    var coverURL: URL? {
        SavedGeneration.existingCoverURL(id: id)
    }
}
