import Foundation

/// Plain file I/O for generated chapter audio — the merged
/// `chapter_<i>.wav` + `chapter_<i>.json` sidecar, and the staging
/// directory synthesis writes into chunk-by-chunk before the merge. Kept
/// separate from `ChapterSynthesisService` (which owns the actual
/// synthesis + merge *logic*) so file-path/on-disk-layout concerns live in
/// one small, easily-audited place — same split `SavedGeneration` already
/// draws between "where files live" and whoever writes them.
///
/// Errors are thrown, not swallowed with `try?` the way the old
/// `attachAudio` did — a 30+MB chapter write can genuinely fail (full
/// disk), and the caller needs to know.
enum PageAudioStore {
    // MARK: - Final (merged) chapter audio

    static func isGenerated(_ ref: ReaderPageRef, project: SavedGeneration) -> Bool {
        project.hasGeneratedAudio(pageIndex: ref.pageIndex)
            && FileManager.default.fileExists(
                atPath: project.pageSidecarFileURL(index: ref.pageIndex).path)
    }

    static func loadAudio(_ ref: ReaderPageRef, project: SavedGeneration) -> Data? {
        try? Data(contentsOf: project.pageAudioFileURL(index: ref.pageIndex))
    }

    static func loadManifest(_ ref: ReaderPageRef, project: SavedGeneration) -> ChapterAudioManifest? {
        guard let data = try? Data(contentsOf: project.pageSidecarFileURL(index: ref.pageIndex))
        else { return nil }
        return try? JSONDecoder().decode(ChapterAudioManifest.self, from: data)
    }

    /// Writes the final merged WAV + manifest, then clears any staging
    /// files for this chapter — called once, after `WavConcatenator.merge`
    /// succeeds.
    static func saveFinal(
        audio: Data, manifest: ChapterAudioManifest, ref: ReaderPageRef, project: SavedGeneration
    ) throws {
        try FileManager.default.createDirectory(
            at: project.audioDirectory, withIntermediateDirectories: true)
        try audio.write(to: project.pageAudioFileURL(index: ref.pageIndex))
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: project.pageSidecarFileURL(index: ref.pageIndex))
        clearStaging(ref, project: project)
    }

    static func deleteGeneratedAudio(_ ref: ReaderPageRef, project: SavedGeneration) {
        try? FileManager.default.removeItem(at: project.pageAudioFileURL(index: ref.pageIndex))
        try? FileManager.default.removeItem(at: project.pageSidecarFileURL(index: ref.pageIndex))
    }

    // MARK: - Staging (in-progress synthesis)

    /// One file per synthesis chunk, written as each finishes — so a
    /// killed app or a cancelled Generate can resume from where it left
    /// off instead of restarting, and the merge step doesn't need every
    /// chunk held in memory at once.
    static func stagingDirectory(_ ref: ReaderPageRef, project: SavedGeneration) -> URL {
        project.audioDirectory.appendingPathComponent(".staging_\(ref.pageIndex)", isDirectory: true)
    }

    private static func stagedChunkURL(_ ref: ReaderPageRef, project: SavedGeneration, chunkIndex: Int) -> URL {
        stagingDirectory(ref, project: project).appendingPathComponent("chunk_\(chunkIndex).wav")
    }

    /// Staged chunks already on disk, in order — stops at the first
    /// missing index, so a partial write doesn't return a gappy array.
    static func loadStagedChunks(_ ref: ReaderPageRef, project: SavedGeneration) -> [Data] {
        var chunks: [Data] = []
        while let data = try? Data(contentsOf: stagedChunkURL(ref, project: project, chunkIndex: chunks.count)) {
            chunks.append(data)
        }
        return chunks
    }

    static func saveStagedChunk(
        _ data: Data, ref: ReaderPageRef, project: SavedGeneration, chunkIndex: Int
    ) throws {
        let directory = stagingDirectory(ref, project: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: stagedChunkURL(ref, project: project, chunkIndex: chunkIndex))
    }

    static func clearStaging(_ ref: ReaderPageRef, project: SavedGeneration) {
        try? FileManager.default.removeItem(at: stagingDirectory(ref, project: project))
    }

    // MARK: - Staged word timings

    private static func stagedWordTimingsURL(
        _ ref: ReaderPageRef, project: SavedGeneration, chunkIndex: Int
    ) -> URL {
        stagingDirectory(ref, project: project).appendingPathComponent("chunk_\(chunkIndex).words.json")
    }

    /// Loads word timings for the first `count` staged chunks (the count
    /// `loadStagedChunks` already found — the WAV's presence is
    /// authoritative for "how many chunks are staged", not this file). A
    /// missing or corrupt timings file reads as empty (chunk-level
    /// fallback for that one chunk) rather than stopping the whole load,
    /// so a crash between writing the two files on a prior run can't
    /// desync this array's length from `loadStagedChunks`'.
    static func loadStagedWordTimings(
        _ ref: ReaderPageRef, project: SavedGeneration, count: Int
    ) -> [[WordTiming]] {
        (0..<count).map { index in
            guard
                let data = try? Data(
                    contentsOf: stagedWordTimingsURL(ref, project: project, chunkIndex: index)),
                let timings = try? JSONDecoder().decode([WordTiming].self, from: data)
            else { return [] }
            return timings
        }
    }

    static func saveStagedWordTimings(
        _ timings: [WordTiming], ref: ReaderPageRef, project: SavedGeneration, chunkIndex: Int
    ) throws {
        let directory = stagingDirectory(ref, project: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(timings)
        try data.write(to: stagedWordTimingsURL(ref, project: project, chunkIndex: chunkIndex))
    }
}
