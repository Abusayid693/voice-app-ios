import Foundation

/// Owns the lightweight library index, project metadata, and independently
/// persisted page bodies.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var savedGenerations: [SavedGenerationSummary] = []
    private static let didClearChapterStorageKey = "didClearChapterStorageForPageReader"

    init() {
        Self.clearChapterStorageIfNeeded()
        savedGenerations = Self.loadIndex()
    }

    @discardableResult
    func save(text: String, engine: Engine, voiceName: String) -> UUID? {
        let pages = PageSplitter.split(text)
        guard !pages.isEmpty else { return nil }
        return saveProject(
            title: Self.defaultTitle(for: text), pages: pages,
            engine: engine, voiceName: voiceName)
    }

    /// Copies finalized PDF page files without decoding the full document.
    @discardableResult
    func saveImportedPDF(
        title: String, pagesDirectory: URL, pageCount: Int, coverURL: URL?,
        engine: Engine, voiceName: String
    ) -> UUID? {
        guard pageCount > 0 else { return nil }
        let id = UUID()
        let entry = SavedGeneration(
            id: id, title: title, engine: engine, voiceName: voiceName,
            createdAt: Date(), pageCount: pageCount, source: .pdf)
        let destination = SavedGeneration.projectPagesDirectory(id: id)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pagesDirectory, to: destination)
            if let coverURL, FileManager.default.fileExists(atPath: coverURL.path) {
                // A cover is visual polish, not a reason to reject the
                // readable project if a raster file is unexpectedly bad.
                try? FileManager.default.copyItem(
                    at: coverURL, to: SavedGeneration.coverFileURL(id: id))
            }
            try persist(entry)
            return id
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: SavedGeneration.projectFileURL(id: id))
            return nil
        }
    }

    func project(for id: UUID) -> SavedGeneration? {
        let url = SavedGeneration.projectFileURL(id: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedGeneration.self, from: data)
    }

    func page(for project: SavedGeneration, index: Int) -> ReaderPage? {
        guard index >= 0, index < project.pageCount else { return nil }
        let url = SavedGeneration.pageFileURL(projectID: project.id, index: index)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReaderPage.self, from: data)
    }

    /// Reads one page only when its row becomes visible in the picker, then
    /// retains just a short normalized excerpt in the sheet's local cache.
    func pagePreview(for project: SavedGeneration, index: Int) -> ReaderPagePreview? {
        guard let page = page(for: project, index: index) else { return nil }
        let normalized = page.text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else {
            return ReaderPagePreview(index: index, excerpt: "No selectable text", isBlank: true)
        }
        let excerpt: String
        if normalized.count > 120 {
            excerpt = "\(normalized.prefix(120))…"
        } else {
            excerpt = normalized
        }
        return ReaderPagePreview(index: index, excerpt: excerpt, isBlank: false)
    }

    /// Records successful page changes without disturbing the library's
    /// creation-date ordering in its lightweight project index.
    func recordLastReadPage(index: Int, for projectID: UUID) {
        guard var project = project(for: projectID), index >= 0, index < project.pageCount else { return }
        guard project.lastReadPageIndex != index else { return }
        project.lastReadPageIndex = index
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: SavedGeneration.projectFileURL(id: projectID), options: .atomic)
    }

    /// Changes the project-wide voice and removes audio synthesized with the
    /// previous voice so saved playback can never use stale narration.
    @discardableResult
    func updateVoice(_ voiceName: String, for projectID: UUID) -> Bool {
        guard var project = project(for: projectID) else { return false }
        guard project.voiceName != voiceName else { return true }
        project.voiceName = voiceName
        guard let data = try? JSONEncoder().encode(project) else { return false }

        do {
            if FileManager.default.fileExists(atPath: project.audioDirectory.path) {
                try FileManager.default.removeItem(at: project.audioDirectory)
            }
            try data.write(to: SavedGeneration.projectFileURL(id: projectID), options: .atomic)
            if let index = savedGenerations.firstIndex(where: { $0.id == projectID }) {
                savedGenerations[index] = project.summary
                Self.persistIndex(savedGenerations)
            }
            return true
        } catch {
            return false
        }
    }

    /// Persists a book's Book Shelf orientation (cover vs. spine). Unlike
    /// `updateVoice` this touches no audio — it's purely how the shelf draws
    /// the book — so it just rewrites metadata and republishes the summary.
    @discardableResult
    func updateShelfDisplayMode(_ mode: ShelfDisplayMode, for projectID: UUID) -> Bool {
        guard var project = project(for: projectID) else { return false }
        guard project.shelfDisplayMode != mode else { return true }
        project.shelfDisplayMode = mode
        guard let data = try? JSONEncoder().encode(project) else { return false }

        do {
            try data.write(to: SavedGeneration.projectFileURL(id: projectID), options: .atomic)
            if let index = savedGenerations.firstIndex(where: { $0.id == projectID }) {
                savedGenerations[index] = project.summary
                Self.persistIndex(savedGenerations)
            }
            return true
        } catch {
            return false
        }
    }

    func delete(_ generation: SavedGenerationSummary) {
        savedGenerations.removeAll { $0.id == generation.id }
        Self.persistIndex(savedGenerations)
        try? FileManager.default.removeItem(at: SavedGeneration.projectFileURL(id: generation.id))
        try? FileManager.default.removeItem(
            at: SavedGeneration.projectPagesDirectory(id: generation.id).deletingLastPathComponent())
        try? FileManager.default.removeItem(
            at: SavedGeneration.baseDirectory.appendingPathComponent(generation.id.uuidString))
    }

    private func saveProject(
        title: String, pages: [ReaderPage], engine: Engine, voiceName: String
    ) -> UUID? {
        let id = UUID()
        let entry = SavedGeneration(
            id: id, title: title, engine: engine, voiceName: voiceName,
            createdAt: Date(), pageCount: pages.count, source: .enteredText)
        let directory = SavedGeneration.projectPagesDirectory(id: id)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for page in pages {
                let data = try JSONEncoder().encode(page)
                try data.write(
                    to: SavedGeneration.pageFileURL(projectID: id, index: page.index),
                    options: .atomic)
            }
            try persist(entry)
            return id
        } catch {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: SavedGeneration.projectFileURL(id: id))
            return nil
        }
    }

    private func persist(_ entry: SavedGeneration) throws {
        let data = try JSONEncoder().encode(entry)
        try FileManager.default.createDirectory(
            at: SavedGeneration.projectsDirectory, withIntermediateDirectories: true)
        try data.write(to: SavedGeneration.projectFileURL(id: entry.id), options: .atomic)
        savedGenerations.removeAll { $0.id == entry.id }
        savedGenerations.insert(entry.summary, at: 0)
        Self.persistIndex(savedGenerations)
    }

    private static func loadIndex() -> [SavedGenerationSummary] {
        guard let data = try? Data(contentsOf: SavedGeneration.indexURL) else { return [] }
        return (try? JSONDecoder().decode([SavedGenerationSummary].self, from: data)) ?? []
    }

    private static func persistIndex(_ items: [SavedGenerationSummary]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: SavedGeneration.baseDirectory, withIntermediateDirectories: true)
        try? data.write(to: SavedGeneration.indexURL, options: .atomic)
    }

    private static func clearChapterStorageIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didClearChapterStorageKey) else { return }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyDirectory = appSupport.appendingPathComponent(
            "SavedGenerations", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: legacyDirectory.path) {
                try FileManager.default.removeItem(at: legacyDirectory)
            }
            defaults.removeObject(forKey: "savedGenerations")
            defaults.set(true, forKey: didClearChapterStorageKey)
        } catch {
            // Retry next launch rather than marking a partial cleanup done.
        }
    }

    private static func defaultTitle(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled project"
        guard firstLine.count > 72 else { return firstLine.isEmpty ? "Untitled project" : firstLine }
        return "\(firstLine.prefix(72))…"
    }
}
