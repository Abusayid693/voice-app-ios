import Foundation

/// One "Generate" tap's worth of audio — a self-contained track, like one
/// song in a playlist. Long text still gets split into sub-chunks
/// internally (Kokoro's 510-phoneme cap), but that's invisible here: the
/// whole thing plays back as one continuous track with a single play
/// button, never merged with any other generation's audio.
struct KokoroGeneration: Identifiable {
    let id = UUID()
    let text: String
    var chunkTexts: [String]
    var chunkAudio: [Data?]
    var chunkStates: [ChunkState]
    var isPlaying = false
    var isBuffering = false
    var currentChunkIndex = 0
    /// Set on the first chunk that fails to synthesize — shown on the row
    /// instead of leaving it stuck on "Generating…" forever.
    var error: String?

    /// True once every sub-chunk has audio (or failed) — used for the
    /// row's spinner.
    var isFullyGenerated: Bool {
        !chunkStates.contains(.waiting)
    }
}
