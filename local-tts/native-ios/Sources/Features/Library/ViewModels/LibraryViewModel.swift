import Foundation

/// Owns the persisted list of past generations — a separate concern from
/// TTSViewModel's live generation orchestration, so it gets its own
/// lightweight ViewModel (same reasoning as VoiceCloneViewModel). No
/// Service needed: this is pure local UserDefaults+JSON persistence, no
/// SDK/engine calls.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var savedGenerations: [SavedGeneration] = []

    private static let defaultsKey = "savedGenerations"

    init() {
        savedGenerations = Self.load()
    }

    /// Called from wherever a "Generate" action is triggered (currently
    /// WriteTextView) — saves the text/voice used so it's not lost the
    /// moment the in-memory generation state resets.
    func save(text: String, engine: Engine, voiceName: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = SavedGeneration(id: UUID(), text: text, engine: engine, voiceName: voiceName, createdAt: Date())
        savedGenerations.insert(entry, at: 0)
        Self.persist(savedGenerations)
    }

    func delete(_ generation: SavedGeneration) {
        savedGenerations.removeAll { $0.id == generation.id }
        Self.persist(savedGenerations)
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
