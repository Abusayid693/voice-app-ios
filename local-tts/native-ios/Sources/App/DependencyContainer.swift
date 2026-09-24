import AVFoundation
import FluidAudio

/// Long-lived instances shared across the app's TTS engines — created once
/// here (not per-View-init) so the CoreML managers and the AVAudioEngine
/// graph aren't torn down and rebuilt on every SwiftUI re-render.
final class DependencyContainer {
    // FluidAudio's own hosted ANE repo only publishes af_heart (a real
    // model-conversion constraint, not a missing download — see
    // docs/adr/0002-custom-kokoro-model-bundle.md). This app instead ships
    // a locally-converted (laishere/kokoro-coreml) model set bundled at
    // CustomKokoroModel/, paired with FluidAudio's real
    // KokoroNoise_v2/KokoroTail_v2 stages (our own stock conversion of
    // those two had audible pitch/loudness bugs), so every standard
    // Kokoro-82M English voice actually works.
    // KokoroAneResourceDownloader.ensureVoicePack
    // finds each voice's .bin already present here and never touches the
    // network.
    let kokoroManager: KokoroAneManager
    // The writable directory backing `kokoroManager` above (nil if the
    // bundled copy failed and it fell back to the plain default manager).
    // `KokoroEngineService` needs this too — `KokoroAneResourceDownloader
    // .ensureModels()` defaults to a *different* cache directory when given
    // no override, which would otherwise check/download into a path this
    // manager never reads from.
    let kokoroModelDirectory: URL?
    // True once the bundled CustomKokoroModel/ was found and successfully
    // copied into Application Support — i.e. the Kokoro pack is ready with
    // no network involved at all. Drives the Setup screen's "already
    // downloaded" state for Kokoro.
    let isKokoroPackBundled: Bool

    private static func makeKokoroManager() -> (
        manager: KokoroAneManager, directory: URL?, isBundled: Bool
    ) {
        // Bundle.main.url(forResource:withExtension:) proved unreliable for
        // locating this folder reference on-device (silently returned nil,
        // which fell back to the plain default manager and 404'd trying
        // af_bella against FluidAudio's real repo). Build the path directly
        // against the bundle root instead — matches exactly what we
        // verified on disk in the built .app (CustomKokoroModel/ sits at
        // the bundle's top level, sibling to the executable).
        let bundledDir = Bundle.main.bundleURL.appendingPathComponent("CustomKokoroModel")
        guard FileManager.default.fileExists(atPath: bundledDir.path) else {
            return (KokoroAneManager(), nil, false)
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
            return (KokoroAneManager(), nil, false)
        }
        // defaultVoice is mostly moot — TTSViewModel always passes an
        // explicit voice — but af_heart is a sane fallback.
        return (KokoroAneManager(defaultVoice: "af_heart", directory: writableDir), writableDir, true)
    }

    init() {
        let setup = DependencyContainer.makeKokoroManager()
        kokoroManager = setup.manager
        kokoroModelDirectory = setup.directory
        isKokoroPackBundled = setup.isBundled
    }

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

    // Mandarin/Japanese have no bundled fallback like English's
    // CustomKokoroModel/ — FluidAudio's own hosted ANE-zh/ANE-ja repos have
    // everything needed (7-stage chain + G2P frontend assets + voices), so
    // these are real, network-downloaded managers, same shape as the
    // Pocket managers below. `directory: nil` lets
    // KokoroAneResourceDownloader use its own default cache location.
    let kokoroMandarinManager = KokoroAneManager(variant: .mandarin, defaultVoice: "zf_001")
    // Japanese requires FluidAudio pinned past v0.15.7 (see project.yml) —
    // KokoroAneManager.phonemes(for:) unconditionally threw for this
    // variant before FluidInference/FluidAudio#915 added a real MeCab +
    // Cutlet text frontend.
    let kokoroJapaneseManager = KokoroAneManager(variant: .japanese, defaultVoice: "jf_alpha")

    // One manager per language — PocketTtsManager.language is fixed at
    // init ("to switch languages, create a new manager", per the SDK's own
    // doc comment), so supporting multiple languages means multiple
    // instances, not a mutable property on one. All share the audio
    // engine/node below (that's output-only plumbing, not per-manager
    // state — only one language ever generates/plays at a time).
    //
    // .ane keeps the FlowLM + conditioning prefill on the Neural Engine
    // (rank-4 flowlm_step_ane/cond_prefill_ane) instead of GPU — the SDK
    // defaults to .gpu, but that default is benchmarked on M-series Macs;
    // .ane is documented as the iOS-appropriate placement. Precision is
    // ignored under .ane (those variants are fp16-only).
    let pocketManagers: [PocketLanguage: PocketTtsManager] = Dictionary(
        uniqueKeysWithValues: PocketLanguage.allCases.map {
            ($0, PocketTtsManager(language: $0.sdkLanguage, placement: .ane))
        })

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

    // Lazy so opening/creating the SwiftData store doesn't tax cold
    // launch — only constructed on first actual use (the reader's first
    // playback of this app run). See ReadingStatsStore's own doc comment.
    lazy var readingStatsStore = ReadingStatsStore()
}
