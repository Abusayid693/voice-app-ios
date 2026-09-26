import FluidAudio
import Foundation

/// Long-lived instances shared across the app's Kokoro engines — created
/// once here (not per-View-init) so the CoreML managers aren't torn down
/// and rebuilt on every SwiftUI re-render.
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

    /// Every Kokoro stage on the ANE or the CPU, and **none on the GPU**.
    ///
    /// FluidAudio's default on this OS line puts the noise and tail (iSTFT)
    /// stages on `.cpuAndGPU`, which is faster — but iOS refuses Metal work to
    /// a backgrounded app outright (`kIOGPUCommandBufferCallbackError`
    /// `BackgroundExecutionNotPermitted`), and the failure surfaces as an
    /// MPSGraph assertion that aborts the process rather than an error we could
    /// catch. So synthesis while the screen is locked is impossible on the GPU
    /// route, at any deployment target — the restriction is not version
    /// specific. This is the routing FluidAudio itself defaults to on OS 27+.
    static let kokoroComputeUnits: KokoroAneComputeUnits = .aneTailCpu

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
            return (KokoroAneManager(computeUnits: kokoroComputeUnits), nil, false)
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
            return (KokoroAneManager(computeUnits: kokoroComputeUnits), nil, false)
        }
        // defaultVoice is mostly moot — TTSViewModel always passes an
        // explicit voice — but af_heart is a sane fallback.
        return (
            KokoroAneManager(
                defaultVoice: "af_heart", directory: writableDir,
                computeUnits: kokoroComputeUnits),
            writableDir, true)
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
    // these are real, network-downloaded managers. `directory: nil` lets
    // KokoroAneResourceDownloader use its own default cache location.
    let kokoroMandarinManager = KokoroAneManager(
        variant: .mandarin, defaultVoice: "zf_001",
        computeUnits: DependencyContainer.kokoroComputeUnits)
    // Japanese requires FluidAudio pinned past v0.15.7 (see project.yml) —
    // KokoroAneManager.phonemes(for:) unconditionally threw for this
    // variant before FluidInference/FluidAudio#915 added a real MeCab +
    // Cutlet text frontend.
    let kokoroJapaneseManager = KokoroAneManager(
        variant: .japanese, defaultVoice: "jf_alpha",
        computeUnits: DependencyContainer.kokoroComputeUnits)

    // Lazy so opening/creating the SwiftData store doesn't tax cold
    // launch — only constructed on first actual use (the reader's first
    // playback of this app run). See ReadingStatsStore's own doc comment.
    lazy var readingStatsStore = ReadingStatsStore()
}
