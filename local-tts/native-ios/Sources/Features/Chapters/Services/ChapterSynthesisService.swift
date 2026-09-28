import AVFoundation
import FluidAudio
import Foundation

/// Owns Kokoro chapter synthesis: resolving which variant's manager a
/// voice belongs to, warming it up, and running the actual `synthesize()`
/// calls — one chunk at a time. Two entry points share one FIFO, differing
/// only in how they hand audio back: `synthesizeChunkSamples` returns raw
/// `[Float]` samples plus word timings, which is what `BookAudioPlayer`
/// (the app's one player) needs to fill an `AVAudioPCMBuffer` and highlight
/// words from the same result; `synthesizeChunkDetailed` returns WAV and
/// survives for `StreamingPlaybackLab`, its only remaining caller. Both
/// derive timings the same way for English voices. Nothing here is
/// persisted to disk (there is no "Generate" feature — removed, see
/// CHANGELOG).
///
/// `KokoroAneManager` is itself an actor, so concurrent `synthesize()`
/// calls are memory-safe on their own, but `runSerially` still gives
/// requests a FIFO queue — the reader's bounded-lookahead pump, an
/// on-demand "Play from here" tap, and music-mode's own pump all submit
/// here, and without ordering they'd interleave unpredictably rather than
/// each waiting behind at most one chunk already in flight.
@MainActor
final class ChapterSynthesisService {
    private let kokoroServices: [KokoroVariant: KokoroEngineService]
    private var tail: Task<Void, Error>?

    init(kokoroServices: [KokoroVariant: KokoroEngineService]) {
        self.kokoroServices = kokoroServices
    }

    /// Synthesizes one chunk to WAV with word-level timing data. Only
    /// `StreamingPlaybackLab` still uses this — the app's own player takes
    /// `synthesizeChunkSamples` below, which skips the encode.
    func synthesizeChunkDetailed(
        chunkText: String, voice: String
    ) async throws -> (data: Data, wordTimings: [WordTiming], duration: TimeInterval) {
        try await runSerially {
            let service = try self.service(forVoice: voice)
            try await service.ensureReady(voice: voice)
            return try await Self.synthesizeOneChunk(chunkText: chunkText, voice: voice, service: service)
        }
    }

    /// Synthesizes one chunk as raw samples plus word timings — the app's
    /// one playback path (`BookAudioPlayer`), which feeds an
    /// `AVAudioPCMBuffer` directly and highlights words from the same
    /// result. Same FIFO, same `ensureReady`, same text normalization as
    /// `synthesizeChunkDetailed`; what differs is the *audio* representation.
    /// English voices stop at `synthesizeDetailed`'s own pre-encode
    /// `.samples`, skipping the `AudioWAV` encode and the caller's matching
    /// decode — a pure round-trip for a node that wants floats anyway.
    /// Non-English voices still go through plain `synthesize` (WAV), since
    /// there's no `synthesizeDetailed` path proven safe for them yet, and
    /// get no word timings — the alignment relies on the English
    /// normalizer/phonemizer path, the same fallback chunk-level
    /// highlighting has always used.
    func synthesizeChunkSamples(
        chunkText: String, voice: String
    ) async throws -> (
        samples: [Float], sampleRate: Int, duration: TimeInterval, wordTimings: [WordTiming]
    ) {
        try await runSerially {
            let service = try self.service(forVoice: voice)
            try await service.ensureReady(voice: voice)
            let spoken = Self.spokenText(chunkText)
            guard VoiceCatalog.variant(forCode: voice) == .english else {
                let data = try await service.synthesize(text: spoken, voice: voice)
                let decoded = try Self.samples(fromWAV: data)
                return (decoded.samples, decoded.sampleRate, decoded.duration, [])
            }
            let result = try await service.synthesizeDetailed(text: spoken, voice: voice)
            let wordTimings = await Self.deriveWordTimings(
                chunkText: chunkText, result: result, service: service)
            return (result.samples, result.sampleRate, result.durationSeconds, wordTimings)
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

    /// Decodes a canonical 16-bit mono WAV (what `synthesize()` always
    /// returns) back into `[Float]` samples — only the non-English fallback
    /// in `synthesizeChunkSamples` needs this; English stays on
    /// `synthesizeDetailed`'s samples and never touches WAV at all. Walks
    /// the RIFF chunk list rather than assuming a fixed 44-byte header, same
    /// approach as `StreamingPlaybackLab.pcmBuffer(fromWAV:)` (which parses
    /// the same shape of WAV into an `AVAudioPCMBuffer` instead — a
    /// player-layer concern this service doesn't own).
    private static func samples(
        fromWAV wav: Data
    ) throws -> (samples: [Float], sampleRate: Int, duration: TimeInterval) {
        let bytes = [UInt8](wav)
        guard bytes.count > 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("WAVE".utf8)
        else { throw SynthesisError.malformedWAV }

        var offset = 12
        var sampleRate = 0
        var bitsPerSample = 0
        var pcm: ArraySlice<UInt8>?
        while offset + 8 <= bytes.count {
            let identifier = Array(bytes[offset..<(offset + 4)])
            let size = Int(readUInt32LE(bytes, at: offset + 4))
            let body = offset + 8
            guard size >= 0, body + size <= bytes.count else { break }
            if identifier == Array("fmt ".utf8), size >= 16 {
                sampleRate = Int(readUInt32LE(bytes, at: body + 4))
                bitsPerSample = Int(readUInt16LE(bytes, at: body + 14))
            } else if identifier == Array("data".utf8) {
                pcm = bytes[body..<(body + size)]
            }
            offset = body + size + (size % 2)  // RIFF chunks are word aligned
        }

        guard bitsPerSample == 16, sampleRate > 0, let pcm, !pcm.isEmpty
        else { throw SynthesisError.malformedWAV }

        let frameCount = pcm.count / 2
        var samples = [Float](repeating: 0, count: frameCount)
        let base = pcm.startIndex
        for frame in 0..<frameCount {
            let index = base + frame * 2
            let raw = UInt16(pcm[index]) | (UInt16(pcm[index + 1]) << 8)
            samples[frame] = Float(Int16(bitPattern: raw)) / 32768
        }
        return (samples, sampleRate, Double(frameCount) / Double(sampleRate))
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
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
        case malformedWAV
    }
}
