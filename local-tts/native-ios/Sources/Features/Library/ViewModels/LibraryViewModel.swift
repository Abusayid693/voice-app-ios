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

    /// Copies finalized page files without decoding the full document. Shared
    /// by every imported format — only `source` and the two format-specific
    /// side files (the source document, the chapter list) differ.
    @discardableResult
    func saveImportedBook(
        id: UUID, title: String, createdAt: Date, shelfOrder: Int?,
        pagesDirectory: URL, sourceURL: URL?, pageCount: Int, coverURL: URL?,
        spineArtworkURL: URL?, chaptersURL: URL? = nil,
        source: SavedProjectSource = .pdf,
        engine: Engine, voiceName: String
    ) -> UUID? {
        guard pageCount > 0 else { return nil }
        if let existing = project(for: id) {
            // Absorbs a duplicate completion callback. Still refuses to adopt
            // a project that was saved as something other than an imported
            // book, so typed text can never be clobbered by a colliding id.
            guard existing.source.isShelfBook else { return nil }
            savedGenerations.removeAll { $0.id == id }
            savedGenerations.append(existing.summary)
            savedGenerations.sort { $0.createdAt > $1.createdAt }
            Self.persistIndex(savedGenerations)
            return id
        }

        let entry = SavedGeneration(
            id: id, title: title, engine: engine, voiceName: voiceName,
            createdAt: createdAt, pageCount: pageCount, source: source,
            shelfOrder: shelfOrder)
        let projectDirectory = SavedGeneration.projectDirectory(id: id)
        let destination = SavedGeneration.projectPagesDirectory(id: id)

        do {
            // A terminated finalization can leave copied files before the
            // metadata commit. Rebuild that incomplete destination in place.
            if FileManager.default.fileExists(atPath: projectDirectory.path) {
                try FileManager.default.removeItem(at: projectDirectory)
            }
            try? FileManager.default.removeItem(at: SavedGeneration.projectFileURL(id: id))
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pagesDirectory, to: destination)
            if let coverURL, FileManager.default.fileExists(atPath: coverURL.path) {
                // A cover is visual polish, not a reason to reject the
                // readable project if a raster file is unexpectedly bad.
                try? FileManager.default.copyItem(
                    at: coverURL, to: SavedGeneration.coverFileURL(id: id))
            }
            if let spineArtworkURL,
               FileManager.default.fileExists(atPath: spineArtworkURL.path)
            {
                try? FileManager.default.copyItem(
                    at: spineArtworkURL,
                    to: SavedGeneration.spineArtworkFileURL(id: id))
            }
            // PDFs only. `existingSourcePDFURL` is what gates the reader's
            // original-page view, and that view renders its file *as a PDF* —
            // so copying an EPUB to the same path would offer a control that
            // cannot work. An EPUB simply has no original-page mode.
            if source == .pdf, let sourceURL,
               FileManager.default.fileExists(atPath: sourceURL.path)
            {
                // Best-effort for the same reason as the artwork above:
                // without it the reader just can't offer the original-page
                // view, which is no reason to fail a readable import.
                try? FileManager.default.copyItem(
                    at: sourceURL, to: SavedGeneration.sourcePDFFileURL(id: id))
            }
            if let chaptersURL, FileManager.default.fileExists(atPath: chaptersURL.path) {
                try? FileManager.default.copyItem(
                    at: chaptersURL, to: SavedGeneration.chaptersFileURL(id: id))
            }
            try persist(entry)
            return id
        } catch {
            try? FileManager.default.removeItem(at: projectDirectory)
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

    /// `[]` for a PDF, or an EPUB with no table of contents resolved — both
    /// are the same "nothing to show" case to a caller.
    func chapters(for project: SavedGeneration) -> [EPUBChapter] {
        guard let url = SavedGeneration.existingChaptersURL(id: project.id),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([EPUBChapter].self, from: data)) ?? []
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

    /// Changes the project-wide voice. Playback is always synthesized on
    /// demand (there is no persisted "Generate" audio to invalidate), so
    /// this just rewrites metadata — the reader picks up the new voice the
    /// next time it starts streaming.
    @discardableResult
    func updateVoice(_ voiceName: String, for projectID: UUID) -> Bool {
        guard var project = project(for: projectID) else { return false }
        guard project.voiceName != voiceName else { return true }
        project.voiceName = voiceName
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

    /// Persists a book's Book Shelf orientation (cover vs. spine) — purely how
    /// the shelf draws the book, so it just rewrites metadata and republishes
    /// the summary.
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
