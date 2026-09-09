import AVFoundation
import FluidAudio

/// Long-lived instances shared across the app's TTS engines — created once
/// here (not per-View-init) so the CoreML managers and the AVAudioEngine
/// graph aren't torn down and rebuilt on every SwiftUI re-render.
final class DependencyContainer {
    let kokoroManager = KokoroAneManager()

    // .ane keeps the FlowLM + conditioning prefill on the Neural Engine
    // (rank-4 flowlm_step_ane/cond_prefill_ane) instead of GPU — the SDK
    // defaults to .gpu, but that default is benchmarked on M-series Macs;
    // .ane is documented as the iOS-appropriate placement. Precision is
    // ignored under .ane (those variants are fp16-only).
    let pocketManager = PocketTtsManager(language: .english, placement: .ane)

    // PocketTTS streams 80ms frames rather than one complete WAV, so
    // playback goes through AVAudioEngine/AVAudioPlayerNode (which accepts
    // buffers incrementally) instead of AVAudioPlayer (which needs the
    // whole file up front).
    let audioEngine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    let streamFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(PocketTtsConstants.audioSampleRate),
        channels: 1,
        interleaved: false)!
}
