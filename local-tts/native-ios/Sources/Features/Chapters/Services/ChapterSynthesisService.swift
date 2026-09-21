import AVFoundation
import FluidAudio
import Foundation

/// Owns Kokoro chapter synthesis: resolving which variant's manager a
/// voice belongs to, warming it up, running the actual `synthesize()`
/// calls, and merging a chapter's chunks into one saved WAV. Used both for
/// streaming (one chunk at a time, via `synthesizeChunkDetailed`) and for a
/// chapter's Generate button (`generateAndSave`, the whole chapter as one
/// job) — both funnel through `synthesizeOneChunk`, the shared per-chunk
/// logic (English gets real word timings via `synthesizeDetailed`;
/// non-English just audio).
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

    /// Synthesizes one chunk with word-level timing data — the streaming
    /// path (`ChapterAudioPlayer.stream`), which retains the result itself
    /// for in-session seeking. Not persisted to disk; that only happens via
    /// `generateAndSave`.
    func synthesizeChunkDetailed(
        chunkText: String, voice: String
    ) async throws -> (data: Data, wordTimings: [WordTiming], duration: TimeInterval) {
        try await runSerially {
            let service = try self.service(forVoice: voice)
            try await service.ensureReady(voice: voice)
            return try await Self.synthesizeOneChunk(chunkText: chunkText, voice: voice, service: service)
        }
    }

    /// What actually gets fed to the engine: the chunk's text with every
    /// whitespace run collapsed to one space.
    ///
    /// Chunk text carries real newlines now (a paragraph break inside a
    /// chunk is preserved for display and for word-timing separators), but
    /// newlines carry no phonetic information — Kokoro's own `splitWords`
    /// treats every whitespace run as one word boundary regardless. The
    /// NeMo FST normalizer that runs *before* that is opaque compiled Rust,
    /// so feeding it raw paragraph breaks risks it mishandling or
    /// truncating there, which would silently cut the audio short. Word
    /// count and order are identical either way, so timing alignment is
    /// unaffected.
    private static func spokenText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
            var stagedWordTimings = ChapterAudioStore.loadStagedWordTimings(
                ref, project: project, count: stagedChunks.count)
            onProgress(stagedChunks.count, chunkTexts.count)

            for index in stagedChunks.count..<chunkTexts.count {
                try Task.checkCancellation()
                let (data, wordTimings, _) = try await Self.synthesizeOneChunk(
                    chunkText: chunkTexts[index], voice: voice, service: service)
                try ChapterAudioStore.saveStagedChunk(data, ref: ref, project: project, chunkIndex: index)
                try ChapterAudioStore.saveStagedWordTimings(
                    wordTimings, ref: ref, project: project, chunkIndex: index)
                stagedChunks.append(data)
                stagedWordTimings.append(wordTimings)
                onProgress(stagedChunks.count, chunkTexts.count)
            }

            let (merged, chunkStarts) = try WavConcatenator.merge(stagedChunks)
            let mergedPlayer = try? AVAudioPlayer(data: merged)

            let manifest = ChapterAudioManifest(
                schemaVersion: ChapterAudioManifest.currentSchemaVersion,
                sampleRate: mergedPlayer?.format.sampleRate ?? 24_000,
                totalDuration: mergedPlayer?.duration ?? 0, chunkTexts: chunkTexts,
                chunkStarts: chunkStarts, wordTimings: stagedWordTimings)
            try ChapterAudioStore.saveFinal(audio: merged, manifest: manifest, ref: ref, project: project)
        }
    }

    /// The shared per-chunk synthesis logic both `generateAndSave` and
    /// `synthesizeChunkDetailed` funnel through. English voices get exact
    /// word-level timings (see `WordTimingDeriver`) via `synthesizeDetailed`
    /// instead of the plain `synthesize`, since only that call exposes the
    /// real per-token duration data used to render the audio. Non-English
    /// voices skip this — the alignment relies on the English normalizer/
    /// phonemizer path — and get an empty `wordTimings`, same fallback
    /// chunk-level highlighting already uses.
    private static func synthesizeOneChunk(
        chunkText: String, voice: String, service: KokoroEngineService
    ) async throws -> (data: Data, wordTimings: [WordTiming], duration: TimeInterval) {
        let spoken = spokenText(chunkText)
        guard VoiceCatalog.variant(forCode: voice) == .english else {
            let data = try await service.synthesize(text: spoken, voice: voice)
            let duration = (try? AVAudioPlayer(data: data))?.duration ?? 0
            return (data, [], duration)
        }
        let result = try await service.synthesizeDetailed(text: spoken, voice: voice)
        let data = try AudioWAV.data(
            from: result.samples, sampleRate: Double(result.sampleRate), normalize: false)
        let wordTimings = await deriveWordTimings(
            chunkText: chunkText, spokenText: spoken, result: result, service: service)
        return (data, wordTimings, result.durationSeconds)
    }

    /// Runs the two calls `WordTimingDeriver` needs — the public FST
    /// normalizer once for the whole chunk, then a memoized
    /// `phonemes(for:)` per unique normalized word — and hands the result
    /// to the pure deriver. A vocab/space-token load failure degrades this
    /// one chunk to no word timings rather than failing the whole
    /// Generate/stream; audio still returns either way.
    private static func deriveWordTimings(
        chunkText: String, spokenText: String, result: KokoroAneSynthesisResult,
        service: KokoroEngineService
    ) async -> [WordTiming] {
        guard let spaceTokenId = try? service.spaceTokenId() else { return [] }
        // Normalize the same string synthesis actually received, so the
        // normalized word list lines up with the tokens it produced;
        // `chunkText` (newlines intact) stays the display side.
        let normalizedText = NemoTextNormalizer.normalize(spokenText, language: .english)
        let normalizedWords = normalizedText.split(whereSeparator: \.isWhitespace).map(String.init)
        var counts: [String: Int] = [:]
        for word in Set(normalizedWords) {
            counts[word] = await service.phonemeGroupCount(for: word)
        }
        return WordTimingDeriver.derive(
            displayedText: chunkText, normalizedText: normalizedText, result: result,
            spaceTokenId: spaceTokenId, groupCount: { counts[$0] ?? 1 })
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
