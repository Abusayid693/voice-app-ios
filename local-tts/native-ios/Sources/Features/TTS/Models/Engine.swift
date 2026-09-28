/// The app's TTS engines. Kokoro-ANE is the only one — Pocket TTS (and
/// Supertonic-3 before it) were removed, but this stays an enum rather than
/// collapsing to nothing: `SavedGeneration` and `ReadingSession` both persist
/// it, so the case's raw value is part of the on-disk format.
enum Engine: String, Codable, Hashable {
    case kokoroAne = "Kokoro-ANE"
}
