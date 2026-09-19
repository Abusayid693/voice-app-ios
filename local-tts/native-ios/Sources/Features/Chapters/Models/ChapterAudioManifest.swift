import Foundation

/// Sidecar JSON saved alongside a generated chapter's merged WAV
/// (`SavedGeneration.chapterSidecarFileURL`) — records where each
/// synthesis chunk's text landed in the merged file. `chunkStarts` is
/// cumulative (chunk *i* starts at `chunkStarts[i]` seconds into the merged
/// file), not a per-chunk duration, so both read-along highlighting
/// (`chunkStarts.lastIndex(where: { $0 <= elapsed })`) and tap-to-seek
/// (`player.currentTime = chunkStarts[i]`) are a single lookup with no
/// running sum. Replaces the old `playPersistedAudio` approach of
/// re-running `KokoroTextChunker.chunk(text)` and hoping the chunk count
/// still matched what was actually saved.
struct ChapterAudioManifest: Codable {
    let schemaVersion: Int
    let sampleRate: Double
    let totalDuration: TimeInterval
    let chunkTexts: [String]
    let chunkStarts: [TimeInterval]

    static let currentSchemaVersion = 1

    /// Index of the chunk playing at `elapsed` seconds into the merged
    /// file — the last chunk whose start time hasn't been reached yet.
    func chunkIndex(atElapsed elapsed: TimeInterval) -> Int {
        var index = 0
        for (i, start) in chunkStarts.enumerated() where start <= elapsed {
            index = i
        }
        return index
    }
}
