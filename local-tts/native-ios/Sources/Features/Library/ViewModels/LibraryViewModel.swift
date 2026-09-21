import Foundation

/// Owns the library index and file-backed project documents. The index is
/// deliberately small; chapter text is decoded only when a user opens a
/// project, which keeps large PDF imports out of UserDefaults and startup
/// memory.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var savedGenerations: [SavedGenerationSummary] = []

    private static let legacyDefaultsKey = "savedGenerations"
    private static let didCleanUpLegacyChunkAudioKey = "didCleanUpLegacyChunkAudio"

    init() {
        migrateLegacyLibraryIfNeeded()
        savedGenerations = Self.loadIndex()
        cleanUpLegacyChunkAudioIfNeeded()
    }

    @discardableResult
    func save(text: String, engine: Engine, voiceName: String) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entry = SavedGeneration(
            id: UUID(), text: text, engine: engine, voiceName: voiceName, createdAt: Date(),
            chapters: ChapterSplitter.split(text))
        persist(entry)
        return entry.id
    }

    /// Persists a completed PDF import in the existing project format so it
    /// automatically receives the normal library, chapter-list, and player
    /// UX.
    @discardableResult
    func saveImportedPDF(
        title: String, chapters: [Chapter], engine: Engine, voiceName: String
    ) -> UUID? {
        guard !chapters.isEmpty else { return nil }
        let text = chapters.map(\.text).joined(separator: "\n\n")
        let entry = SavedGeneration(
            id: UUID(), title: title, text: text, engine: engine, voiceName: voiceName,
            createdAt: Date(), chapters: chapters)
        persist(entry)
        return entry.id
    }

    /// Loads one complete project on demand. It is intentionally synchronous:
    /// callers invoke it from a tap/swipe action, not from the list render.
    func project(for id: UUID) -> SavedGeneration? {
        let url = SavedGeneration.projectFileURL(id: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedGeneration.self, from: data)
    }

    func delete(_ generation: SavedGenerationSummary) {
        savedGenerations.removeAll { $0.id == generation.id }
        Self.persistIndex(savedGenerations)
        try? FileManager.default.removeItem(at: SavedGeneration.projectFileURL(id: generation.id))
        try? FileManager.default.removeItem(at: generation.audioDirectory)
    }

    private func persist(_ entry: SavedGeneration) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(
                at: SavedGeneration.projectsDirectory, withIntermediateDirectories: true)
            try data.write(to: SavedGeneration.projectFileURL(id: entry.id), options: .atomic)
            savedGenerations.removeAll { $0.id == entry.id }
            savedGenerations.insert(entry.summary, at: 0)
            Self.persistIndex(savedGenerations)
        } catch {
            // The library has no error surface today; leave the in-memory
            // index untouched if the document could not be made durable.
        }
    }

    private static func loadIndex() -> [SavedGenerationSummary] {
        guard let data = try? Data(contentsOf: SavedGeneration.indexURL) else { return [] }
        return (try? JSONDecoder().decode([SavedGenerationSummary].self, from: data)) ?? []
    }

    private static func persistIndex(_ items: [SavedGenerationSummary]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: SavedGeneration.baseDirectory, withIntermediateDirectories: true)
        try? data.write(to: SavedGeneration.indexURL, options: .atomic)
    }

    /// One-time, lossless migration from the old single UserDefaults blob.
    /// It leaves the old value in place until all project files and the new
    /// index were written successfully, then removes it to reclaim space.
    private func migrateLegacyLibraryIfNeeded() {
        guard !FileManager.default.fileExists(atPath: SavedGeneration.indexURL.path) else { return }
        guard
            let data = UserDefaults.standard.data(forKey: Self.legacyDefaultsKey),
            let legacy = try? JSONDecoder().decode([SavedGeneration].self, from: data)
        else { return }

        var summaries: [SavedGenerationSummary] = []
        for entry in legacy {
            guard let encoded = try? JSONEncoder().encode(entry) else { return }
            do {
                try encoded.write(to: SavedGeneration.projectFileURL(id: entry.id), options: .atomic)
                summaries.append(entry.summary)
            } catch {
                return
            }
        }
        Self.persistIndex(summaries)
        guard FileManager.default.fileExists(atPath: SavedGeneration.indexURL.path) else { return }
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    private func cleanUpLegacyChunkAudioIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didCleanUpLegacyChunkAudioKey) else { return }
        for generation in savedGenerations {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: generation.audioDirectory, includingPropertiesForKeys: nil)
            else { continue }
            for file in contents where file.lastPathComponent.hasPrefix("chunk_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        UserDefaults.standard.set(true, forKey: Self.didCleanUpLegacyChunkAudioKey)
    }
}

private extension SavedGenerationSummary {
    var audioDirectory: URL {
        SavedGeneration.baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
