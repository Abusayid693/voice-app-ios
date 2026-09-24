import AVFoundation
import FluidAudio
import Foundation

/// Wraps `PocketTtsManager`'s download/init/streaming-synthesize calls,
/// plus the `AVAudioEngine`/`AVAudioPlayerNode` graph that plays streamed
/// frames back as they're generated. This service owns audio playback —
/// unlike Kokoro's one-shot WAV, PocketTTS's frame-by-frame output needs a
/// persistent engine/node pair kept alive across the whole synthesis.
/// `@MainActor` (constructed once in TTSViewModel.init, shared with
/// VoiceCloneViewModel, both `@MainActor` — same reasoning as
/// `KokoroEngineService`) — needed here specifically so the playback-
/// completion bookkeeping below (mutated both from ordinary calls and from
/// an AVFoundation completion handler that fires off-main) has one
/// well-defined isolation domain instead of being a real data race.
@MainActor
final class PocketEngineService {
    private let manager: PocketTtsManager
    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let streamFormat: AVAudioFormat

    // MARK: - Playback completion (see `schedule`)
    //
    // PocketTTS has no single "finished" signal from the SDK: synthesis
    // exhausting its stream just means no more frames are coming, but
    // AVAudioPlayerNode keeps draining already-scheduled buffers afterwards.
    // Real completion is "synthesis produced its last frame AND every
    // scheduled buffer has actually finished playing" — both halves are
    // required, since outstandingScheduledBufferCount can transiently hit
    // zero *between* two frames arriving, well before the utterance is over.
    private var outstandingScheduledBufferCount = 0
    private var isSynthesisComplete = false
    private var playbackFinishedHandler: (() -> Void)?

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
    /// for, unlike Kokoro's repo download. Uses `manager.language` rather
    /// than a hardcoded value, so this service is correct for whichever
    /// language's manager it was constructed with — one `PocketEngineService`
    /// per `PocketLanguage`, mirroring `DependencyContainer.pocketManagers`.
    func ensureModels(progressHandler: ProgressHandler?) async throws {
        try await PocketTtsResourceDownloader.ensureModels(
            language: manager.language, placement: .ane, progressHandler: progressHandler)
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

    /// Call once before starting a new streaming run — clears state left
    /// over from a previous page/utterance so it can't leak a stale
    /// completion into this one.
    func resetPlaybackCompletionTracking() {
        outstandingScheduledBufferCount = 0
        isSynthesisComplete = false
        playbackFinishedHandler = nil
    }

    /// Registers the closure to call once real audio completion has
    /// happened — see the state block above. Overwrites any previous
    /// handler; callers register this once per run, right before consuming
    /// the synthesis stream.
    func onPlaybackFinished(_ handler: @escaping () -> Void) {
        playbackFinishedHandler = handler
    }

    /// Call once the synthesis stream has been fully consumed (the
    /// `for try await frame in stream` loop exited normally). This is the
    /// "no more frames are coming" half of completion; `schedule`'s
    /// completion callback supplies the other half.
    func markSynthesisComplete() {
        isSynthesisComplete = true
        checkPlaybackCompletion()
    }

    private func checkPlaybackCompletion() {
        guard isSynthesisComplete, outstandingScheduledBufferCount == 0 else { return }
        let handler = playbackFinishedHandler
        playbackFinishedHandler = nil
        handler?()
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

    /// Same as above, but for a cloned voice's conditioning data instead of
    /// a named preset — the two are parallel overloads on the SDK manager.
    func synthesizeStreaming(
        text: String, voiceData: PocketTtsVoiceData
    ) async throws -> AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error> {
        let spokenText = await Task.detached {
            TextNormalizer.shared.tnNormalizeSentence(text)
        }.value
        return try await manager.synthesizeStreaming(text: spokenText, voiceData: voiceData)
    }

    // MARK: - Voice cloning

    /// True once the mimi_encoder model (voice cloning's only extra
    /// dependency beyond the normal Pocket pack) is present on disk.
    func isVoiceCloningAvailable() async -> Bool {
        await manager.isVoiceCloningAvailable()
    }

    /// Downloads the mimi_encoder model on first call if needed (no
    /// progress callback exposed by the SDK for this step), then runs the
    /// given sample through it to produce voice-conditioning data.
    func cloneVoice(from audioURL: URL) async throws -> PocketTtsVoiceData {
        try await manager.cloneVoice(from: audioURL)
    }

    func saveClonedVoice(_ voiceData: PocketTtsVoiceData, to url: URL) throws {
        try manager.saveClonedVoice(voiceData, to: url)
    }

    func loadClonedVoice(from url: URL) throws -> PocketTtsVoiceData {
        try manager.loadClonedVoice(from: url)
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
        outstandingScheduledBufferCount += 1
        // completionCallbackType: .dataPlayedBack fires once this buffer has
        // actually been rendered, not just dequeued — AVFoundation invokes
        // it on an internal audio thread, so every touch of this actor's
        // state below has to hop back via Task { @MainActor in }.
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.outstandingScheduledBufferCount -= 1
                self.checkPlaybackCompletion()
            }
        }
    }
}
