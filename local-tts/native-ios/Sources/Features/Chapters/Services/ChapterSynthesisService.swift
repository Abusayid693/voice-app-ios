import AVFoundation
import FluidAudio
import Foundation

/// Owns Kokoro chapter synthesis: resolving which variant's manager a
/// voice belongs to, warming it up, and running the actual `synthesize()`
/// calls — one chunk at a time, via `synthesizeChunkDetailed`, which is
/// what `ChapterAudioPlayer.stream` retains in memory for the session.
/// Nothing here is persisted to disk (there is no "Generate" feature —
/// removed, see CHANGELOG); `synthesizeOneChunk` is the shared per-chunk
/// logic (English gets real word timings via `synthesizeDetailed`;
/// non-English just audio).
///
/// `KokoroAneManager` is itself an actor, so concurrent `synthesize()`
/// calls are memory-safe on their own, but `runSerially` still gives
/// requests a FIFO queue — the reader's bounded-lookahead pump and an
/// on-demand "Play from here" tap both submit here, and without ordering
/// the two would interleave unpredictably rather than the tap waiting
/// behind at most one chunk already in flight.
@MainActor
final class ChapterSynthesisService {
    private let kokoroServices: [KokoroVariant: KokoroEngineService]
    private var tail: Task<Void, Error>?

    init(kokoroServices: [KokoroVariant: KokoroEngineService]) {
        self.kokoroServices = kokoroServices
    }

    /// Synthesizes one chunk with word-level timing data — the streaming
    /// path (`ChapterAudioPlayer.stream`), which retains the result itself
    /// for in-session seeking. Never persisted to disk.
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

    /// The shared per-chunk synthesis logic `synthesizeChunkDetailed` funnels
    /// through. English voices get exact
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
        let wordTimings = await deriveWordTimings(chunkText: chunkText, result: result, service: service)
        return (data, wordTimings, result.durationSeconds)
    }

    /// Runs the one remaining call `WordTimingDeriver` needs — a memoized
    /// `phonemes(for:)` per unique normalized word — and hands the result
    /// to the pure deriver. A vocab/space-token load failure degrades this
    /// one chunk to no word timings rather than failing the whole
    /// Generate/stream; audio still returns either way.
    private static func deriveWordTimings(
        chunkText: String, result: KokoroAneSynthesisResult, service: KokoroEngineService
    ) async -> [WordTiming] {
        guard let spaceTokenId = try? service.spaceTokenId() else { return [] }
        // The exact text synthesis actually normalized to — straight from
        // the SDK (FluidInference/FluidAudio#944, the fix for #943 this app
        // filed), not re-derived here. Re-running the public FST ourselves
        // used to be both redundant (the SDK already ran it) and risky: its
        // real path falls back to an internal Swift-side normalizer we have
        // no way to call when the FST leaves text unchanged, so our own
        // copy could silently diverge from what was actually spoken. This
        // is ground truth instead of a reconstruction of it.
        guard let normalizedText = result.normalizedText else { return [] }
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
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    enum SynthesisError: Error {
        case unknownVoice(String)
    }
}
