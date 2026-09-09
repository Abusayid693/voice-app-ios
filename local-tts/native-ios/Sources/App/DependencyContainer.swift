import AVFoundation
import FluidAudio

/// Long-lived instances shared across the app's TTS engines — created once
/// here (not per-View-init) so the CoreML managers and the AVAudioEngine
/// graph aren't torn down and rebuilt on every SwiftUI re-render.
final class DependencyContainer {
    // FluidAudio's own hosted ANE repo only publishes af_heart (a real
    // model-conversion constraint, not a missing download — see
    // ENG_CONTEXT.md). This app instead ships a locally-converted
    // (laishere/kokoro-coreml) model set bundled at CustomKokoroModel/,
    // paired with FluidAudio's real KokoroNoise_v2/KokoroTail_v2 stages
    // (our own stock conversion of those two had audible pitch/loudness
    // bugs — see ENG_CONTEXT.md), so every standard Kokoro-82M English
    // voice actually works. KokoroAneResourceDownloader.ensureVoicePack
    // finds each voice's .bin already present here and never touches the
    // network.
    let kokoroManager: KokoroAneManager = {
        // Bundle.main.url(forResource:withExtension:) proved unreliable for
        // locating this folder reference on-device (silently returned nil,
        // which fell back to the plain default manager and 404'd trying
        // af_bella against FluidAudio's real repo). Build the path directly
        // against the bundle root instead — matches exactly what we
        // verified on disk in the built .app (CustomKokoroModel/ sits at
        // the bundle's top level, sibling to the executable).
        let bundledDir = Bundle.main.bundleURL.appendingPathComponent("CustomKokoroModel")
        guard FileManager.default.fileExists(atPath: bundledDir.path) else {
            return KokoroAneManager()
        }
        // The app's own .app bundle is read-only at runtime, but CoreML's
        // ANE compilation step needs to write analytics/cache data back
        // into the model's folder on first load — that's what produced
        // "You don't have permission to save the file 'analytics'...".
        // FluidAudio's normal downloaded models live in Application
        // Support specifically to give CoreML a writable location; copy
        // our bundled models there once (skipped on later launches) so
        // the same thing works for this custom build.
        guard let writableDir = DependencyContainer.writableCopy(ofBundled: bundledDir) else {
            return KokoroAneManager()
        }
        // defaultVoice is mostly moot — TTSViewModel always passes an
        // explicit voice — but af_heart is a sane fallback.
        return KokoroAneManager(defaultVoice: "af_heart", directory: writableDir)
    }()

    private static func writableCopy(ofBundled bundledDir: URL) -> URL? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let destination = appSupport.appendingPathComponent("CustomKokoroModel")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return destination }
        do {
            try fm.createDirectory(
                at: appSupport, withIntermediateDirectories: true)
            try fm.copyItem(at: bundledDir, to: destination)
            return destination
        } catch {
            return nil
        }
    }

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
