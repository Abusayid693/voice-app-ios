import AVFoundation
import FluidAudio
import Foundation

/// Wraps `PocketTtsManager`'s download/init/streaming-synthesize calls,
/// plus the `AVAudioEngine`/`AVAudioPlayerNode` graph that plays streamed
/// frames back as they're generated. This service owns audio playback —
/// unlike Kokoro's one-shot WAV, PocketTTS's frame-by-frame output needs a
/// persistent engine/node pair kept alive across the whole synthesis.
final class PocketEngineService {
    private let manager: PocketTtsManager
    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let streamFormat: AVAudioFormat

    init(
        manager: PocketTtsManager, audioEngine: AVAudioEngine, playerNode: AVAudioPlayerNode,
        streamFormat: AVAudioFormat
    ) {
        self.manager = manager
        self.audioEngine = audioEngine
        self.playerNode = playerNode
        self.streamFormat = streamFormat
    }

    /// Subdirectory downloads (PocketTTS's language packs) span the whole
    /// 0...1 progress fraction — no separate compile phase to reserve room
    /// for, unlike Kokoro's repo download.
    func ensureModels(progressHandler: ProgressHandler?) async throws {
        try await PocketTtsResourceDownloader.ensureModels(
            language: .english, placement: .ane, progressHandler: progressHandler)
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    func preparePlayback() throws {
        if !audioEngine.attachedNodes.contains(playerNode) {
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: streamFormat)
        }
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        playerNode.play()
    }

    func stopPlayback() {
        playerNode.stop()
    }

    /// Normalizes text (numbers/dates/currency — PocketTTS has no built-in
    /// equivalent, unlike Kokoro-ANE, which does this internally) then
    /// streams synthesis frame by frame.
    func synthesizeStreaming(
        text: String, voice: String
    ) async throws -> AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error> {
        // TextNormalizer.shared wraps the same NeMo FST engine Kokoro-ANE
        // uses internally, exposed here as a public, reusable utility. It's
        // a synchronous native call with no `await`, so it runs detached
        // rather than inline — a very long input could otherwise block
        // whichever actor this Task inherited (and stall the UI) instead
        // of yielding like the rest of this pipeline does.
        let spokenText = await Task.detached {
            TextNormalizer.shared.tnNormalizeSentence(text)
        }.value
        return try await manager.synthesizeStreaming(text: spokenText, voice: voice)
    }

    /// Converts one 80ms `AudioFrame` (raw Float32 samples) into a PCM
    /// buffer and hands it to the player node — scheduling returns
    /// immediately, so playback runs concurrently with the next frame's
    /// generation rather than waiting for the whole utterance.
    func schedule(_ frame: PocketTtsSynthesizer.AudioFrame) {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: streamFormat, frameCapacity: AVAudioFrameCount(frame.samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frame.samples.count)
        frame.samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        playerNode.scheduleBuffer(buffer)
    }
}
