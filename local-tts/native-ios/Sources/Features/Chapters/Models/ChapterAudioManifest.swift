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
    /// One entry per chunk, English Kokoro voices only — empty for a
    /// chunk (or the whole chapter, for non-English voices/pre-schema-2
    /// manifests) means no word-level data exists for it.
    let wordTimings: [[WordTiming]]

    static let currentSchemaVersion = 2

    init(
        schemaVersion: Int, sampleRate: Double, totalDuration: TimeInterval, chunkTexts: [String],
        chunkStarts: [TimeInterval], wordTimings: [[WordTiming]]
    ) {
        self.schemaVersion = schemaVersion
        self.sampleRate = sampleRate
        self.totalDuration = totalDuration
        self.chunkTexts = chunkTexts
        self.chunkStarts = chunkStarts
        self.wordTimings = wordTimings
    }

    // Custom decoding: `wordTimings` didn't exist before schema version 2,
    // so a manifest saved by an older build has no such key. `decodeIfPresent`
    // falls back to an empty array per chunk — every chunk just has no
    // word-level data, same as it behaved before this field existed. Same
    // pattern as SavedGeneration.init(from:) uses for its own `chapters` field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        totalDuration = try container.decode(TimeInterval.self, forKey: .totalDuration)
        chunkTexts = try container.decode([String].self, forKey: .chunkTexts)
        chunkStarts = try container.decode([TimeInterval].self, forKey: .chunkStarts)
        wordTimings =
            try container.decodeIfPresent([[WordTiming]].self, forKey: .wordTimings)
            ?? Array(repeating: [], count: chunkTexts.count)
    }

    /// Index of the chunk playing at `elapsed` seconds into the merged
    /// file — the last chunk whose start time hasn't been reached yet.
    func chunkIndex(atElapsed elapsed: TimeInterval) -> Int {
        var index = 0
        for (i, start) in chunkStarts.enumerated() where start <= elapsed {
            index = i
        }
        return index
    }

    /// Index of the word playing at `elapsed` seconds into the merged
    /// file, within `chunkIndex` — nil if that chunk has no word timings
    /// (falls back to highlighting the whole chunk, as before this feature).
    func wordIndex(inChunk chunkIndex: Int, atElapsed elapsed: TimeInterval) -> Int? {
        guard wordTimings.indices.contains(chunkIndex), chunkStarts.indices.contains(chunkIndex) else {
            return nil
        }
        let timings = wordTimings[chunkIndex]
        guard !timings.isEmpty else { return nil }
        let chunkElapsed = elapsed - chunkStarts[chunkIndex]
        var index = 0
        for (i, timing) in timings.enumerated() where timing.start <= chunkElapsed {
            index = i
        }
        return index
    }
}
