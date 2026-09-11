import Foundation

/// A past "Generate" tap's original text + what voice it used — saved so
/// the Library tab has something real to list. Metadata only for now
/// (persisted via UserDefaults+JSON, same style as ClonedVoice); the
/// generated *audio* isn't captured/persisted yet (see issue #11 — Pocket
/// TTS in particular has no accumulated audio buffer to save today, only
/// streamed frames), so a saved entry can be viewed as text but not
/// replayed yet.
struct SavedGeneration: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let engine: Engine
    let voiceName: String
    let createdAt: Date
}
