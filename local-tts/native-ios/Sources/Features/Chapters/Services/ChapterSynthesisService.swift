import AVFoundation
import Foundation

/// Owns Kokoro chapter synthesis: resolving which variant's manager a
/// voice belongs to, warming it up, running the actual `synthesize()`
/// calls, and merging a chapter's chunks into one saved WAV. Used both for
/// streaming (one chunk at a time, via `synthesizeChunk`) and for a
/// chapter's Generate button (`generateAndSave`, the whole chapter as one
/// job).
///
/// `KokoroAneManager` is itself an actor, so concurrent `synthesize()`
/// calls from two callers are memory-safe on their own — but without
/// ordering, a 35-chunk Generate and a stream request would just
/// interleave unpredictably, making the stream's next chunk arrive
/// whenever the manager gets to it. `runSerially` gives requests a FIFO
/// queue instead, so a Play tapped while a Generate is running waits
/// behind it predictably (surfaced in the UI as "waiting", not an
/// indefinite spinner) rather than fighting it chunk-by-chunk.
@MainActor
final class ChapterSynthesisService {
    private let kokoroServices: [KokoroVariant: KokoroEngineService]
    private var tail: Task<Void, Error>?

    init(kokoroServices: [KokoroVariant: KokoroEngineService]) {
        self.kokoroServices = kokoroServices
    }

    /// Synthesizes and plays one synthesis chunk's worth of text — the
    /// streaming path. Not persisted.
    func synthesizeChunk(text: String, voice: String) async throws -> Data {
        try await runSerially {
            let service = try self.service(forVoice: voice)
            try await service.ensureReady(voice: voice)
            return try await service.synthesize(text: text, voice: voice)
        }
    }

    /// Synthesizes every chunk of a chapter, staging each to disk as it
    /// finishes (so a cancelled or interrupted attempt resumes rather than
    /// restarts), then merges them into the chapter's final saved WAV +
    /// sidecar manifest. `onProgress(done, total)` fires after every chunk,
    /// including ones already staged from a prior attempt.
    func generateAndSave(
        ref: ChapterRef, project: SavedGeneration, chapter: Chapter, voice: String,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws {
        try await runSerially {
            try Task.checkCancellation()
            let service = try self.service(forVoice: voice)
            try await service.ensureReady(voice: voice)

            let chunkTexts = KokoroTextChunker.chunk(chapter.text)
            var stagedChunks = ChapterAudioStore.loadStagedChunks(ref, project: project)
            onProgress(stagedChunks.count, chunkTexts.count)

            for index in stagedChunks.count..<chunkTexts.count {
                try Task.checkCancellation()
                let data = try await service.synthesize(text: chunkTexts[index], voice: voice)
                try ChapterAudioStore.saveStagedChunk(data, ref: ref, project: project, chunkIndex: index)
                stagedChunks.append(data)
                onProgress(stagedChunks.count, chunkTexts.count)
            }

            let (merged, chunkStarts) = try WavConcatenator.merge(stagedChunks)
            let mergedPlayer = try? AVAudioPlayer(data: merged)

            let manifest = ChapterAudioManifest(
                schemaVersion: ChapterAudioManifest.currentSchemaVersion,
                sampleRate: mergedPlayer?.format.sampleRate ?? 24_000,
                totalDuration: mergedPlayer?.duration ?? 0, chunkTexts: chunkTexts,
                chunkStarts: chunkStarts)
            try ChapterAudioStore.saveFinal(audio: merged, manifest: manifest, ref: ref, project: project)
        }
    }

    private func service(forVoice voice: String) throws -> KokoroEngineService {
        guard let variant = VoiceCatalog.variant(forCode: voice), let service = kokoroServices[variant]
        else { throw SynthesisError.unknownVoice(voice) }
        return service
    }

    private func runSerially<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            _ = try? await previous?.value
            return try await operation()
        }
        tail = Task<Void, Error> { _ = try await task.value }
        return try await task.value
    }

    enum SynthesisError: Error {
        case unknownVoice(String)
    }
}
