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
enum ChapterAudioStore {
    // MARK: - Final (merged) chapter audio

    static func isGenerated(_ ref: ChapterRef, project: SavedGeneration) -> Bool {
        project.hasGeneratedAudio(chapterIndex: ref.chapterIndex)
    }

    static func loadAudio(_ ref: ChapterRef, project: SavedGeneration) -> Data? {
        try? Data(contentsOf: project.chapterAudioFileURL(index: ref.chapterIndex))
    }

    static func loadManifest(_ ref: ChapterRef, project: SavedGeneration) -> ChapterAudioManifest? {
        guard let data = try? Data(contentsOf: project.chapterSidecarFileURL(index: ref.chapterIndex))
        else { return nil }
        return try? JSONDecoder().decode(ChapterAudioManifest.self, from: data)
    }

    /// Writes the final merged WAV + manifest, then clears any staging
    /// files for this chapter — called once, after `WavConcatenator.merge`
    /// succeeds.
    static func saveFinal(
        audio: Data, manifest: ChapterAudioManifest, ref: ChapterRef, project: SavedGeneration
    ) throws {
        try FileManager.default.createDirectory(
            at: project.audioDirectory, withIntermediateDirectories: true)
        try audio.write(to: project.chapterAudioFileURL(index: ref.chapterIndex))
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: project.chapterSidecarFileURL(index: ref.chapterIndex))
        clearStaging(ref, project: project)
    }

    static func deleteGeneratedAudio(_ ref: ChapterRef, project: SavedGeneration) {
        try? FileManager.default.removeItem(at: project.chapterAudioFileURL(index: ref.chapterIndex))
        try? FileManager.default.removeItem(at: project.chapterSidecarFileURL(index: ref.chapterIndex))
    }

    // MARK: - Staging (in-progress synthesis)

    /// One file per synthesis chunk, written as each finishes — so a
    /// killed app or a cancelled Generate can resume from where it left
    /// off instead of restarting, and the merge step doesn't need every
    /// chunk held in memory at once.
    static func stagingDirectory(_ ref: ChapterRef, project: SavedGeneration) -> URL {
        project.audioDirectory.appendingPathComponent(".staging_\(ref.chapterIndex)", isDirectory: true)
    }

    private static func stagedChunkURL(_ ref: ChapterRef, project: SavedGeneration, chunkIndex: Int) -> URL {
        stagingDirectory(ref, project: project).appendingPathComponent("chunk_\(chunkIndex).wav")
    }

    /// Staged chunks already on disk, in order — stops at the first
    /// missing index, so a partial write doesn't return a gappy array.
    static func loadStagedChunks(_ ref: ChapterRef, project: SavedGeneration) -> [Data] {
        var chunks: [Data] = []
        while let data = try? Data(contentsOf: stagedChunkURL(ref, project: project, chunkIndex: chunks.count)) {
            chunks.append(data)
        }
        return chunks
    }

    static func saveStagedChunk(_ data: Data, ref: ChapterRef, project: SavedGeneration, chunkIndex: Int) throws {
        let directory = stagingDirectory(ref, project: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: stagedChunkURL(ref, project: project, chunkIndex: chunkIndex))
    }

    static func clearStaging(_ ref: ChapterRef, project: SavedGeneration) {
        try? FileManager.default.removeItem(at: stagingDirectory(ref, project: project))
    }
}
