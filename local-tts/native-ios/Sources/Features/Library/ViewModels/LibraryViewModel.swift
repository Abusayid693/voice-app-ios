import Foundation

/// Owns the persisted list of past generations — a separate concern from
/// TTSViewModel's live generation orchestration, so it gets its own
/// lightweight ViewModel (same reasoning as VoiceCloneViewModel). No
/// Service needed: this is pure local UserDefaults+JSON persistence
/// (metadata) plus small file I/O (Kokoro audio), no SDK/engine calls.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var savedGenerations: [SavedGeneration] = []

    private static let defaultsKey = "savedGenerations"

    init() {
        savedGenerations = Self.load()
    }

    /// Called from wherever a "Generate" action is triggered (currently
    /// WriteTextView) — saves the text/voice used so it's not lost the
    /// moment the in-memory generation state resets. Returns the new
    /// entry's id (nil if text was empty) so the caller can later attach
    /// audio to it once generation finishes.
    @discardableResult
    func save(text: String, engine: Engine, voiceName: String) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entry = SavedGeneration(id: UUID(), text: text, engine: engine, voiceName: voiceName, createdAt: Date())
        savedGenerations.insert(entry, at: 0)
        Self.persist(savedGenerations)
        return entry.id
    }

    /// Writes a completed Kokoro generation's per-chunk audio to disk, one
    /// file per chunk (see SavedGeneration.chunkAudioFileURL) — called once
    /// every chunk has finished (TTSViewModel's generateKokoro
    /// `onFullyGenerated` callback), never partway through.
    func attachAudio(_ chunkAudio: [Data], to id: UUID) {
        guard let generation = savedGenerations.first(where: { $0.id == id }) else { return }
        try? FileManager.default.createDirectory(
            at: generation.audioDirectory, withIntermediateDirectories: true)
        for (index, data) in chunkAudio.enumerated() {
            try? data.write(to: generation.chunkAudioFileURL(index: index))
        }
    }

    /// Loads a saved entry's per-chunk audio back, in order — nil if none
    /// was ever saved (Pocket entries, or a Kokoro entry whose generation
    /// never finished). Stops at the first missing index, so a partial
    /// write (e.g. app killed mid-write) doesn't return a gappy array.
    func loadChunkAudio(for generation: SavedGeneration) -> [Data]? {
        var chunks: [Data] = []
        while let data = try? Data(contentsOf: generation.chunkAudioFileURL(index: chunks.count)) {
            chunks.append(data)
        }
        return chunks.isEmpty ? nil : chunks
    }

    func delete(_ generation: SavedGeneration) {
        savedGenerations.removeAll { $0.id == generation.id }
        Self.persist(savedGenerations)
        try? FileManager.default.removeItem(at: generation.audioDirectory)
    }

    private static func load() -> [SavedGeneration] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let items = try? JSONDecoder().decode([SavedGeneration].self, from: data)
        else { return [] }
        return items
    }

    private static func persist(_ items: [SavedGeneration]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
