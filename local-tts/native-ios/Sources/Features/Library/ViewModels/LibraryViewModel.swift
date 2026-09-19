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
    private static let didCleanUpLegacyChunkAudioKey = "didCleanUpLegacyChunkAudio"

    init() {
        savedGenerations = Self.load()
        cleanUpLegacyChunkAudioIfNeeded()
    }

    /// Called from wherever a "Generate" action is triggered (currently
    /// WriteTextView) — saves the text, split into chapters, and the voice
    /// used. No audio is synthesized here anymore: that only happens when
    /// the user taps Generate on an individual chapter later (see
    /// ChaptersListView/ChapterSynthesisService). Returns the new entry's
    /// id (nil if text was empty).
    @discardableResult
    func save(text: String, engine: Engine, voiceName: String) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entry = SavedGeneration(
            id: UUID(), text: text, engine: engine, voiceName: voiceName, createdAt: Date(),
            chapters: ChapterSplitter.split(text))
        savedGenerations.insert(entry, at: 0)
        Self.persist(savedGenerations)
        return entry.id
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

    // One-shot migration: old entries saved flat `chunk_N.wav` files (one
    // per synthesis chunk, not per chapter). Those are superseded by
    // per-chapter merged `chapter_N.wav` files and are never read by the
    // new chapters flow, so they're just dead storage now — delete them
    // rather than migrate. Migrating would mean rebuilding a sidecar
    // manifest via KokoroTextChunker.chunk(text), i.e. carrying forward on
    // day one the exact fragility (re-deriving chunk boundaries and hoping
    // they still match) this redesign exists to remove. Affected entries
    // simply show as not-generated; re-Generate is one tap.
    private func cleanUpLegacyChunkAudioIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didCleanUpLegacyChunkAudioKey) else { return }
        for generation in savedGenerations {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: generation.audioDirectory, includingPropertiesForKeys: nil)
            else { continue }
            for file in contents where file.lastPathComponent.hasPrefix("chunk_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        UserDefaults.standard.set(true, forKey: Self.didCleanUpLegacyChunkAudioKey)
    }
}
