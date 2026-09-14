import FluidAudio
import Foundation

/// Wraps `Supertonic3Manager`'s download/init/synthesize calls — same shape
/// as `KokoroEngineService`. Also loads and caches voice styles, which the
/// SDK takes per `synthesize` call rather than fixing on the manager.
final class Supertonic3EngineService {
    private let manager: Supertonic3Manager
    private let directory: URL?
    // Must match what `manager` was built with, so `ensureModels` pre-fetches
    // the same files `initialize()` later loads.
    private let vectorEstimator: Supertonic3VectorEstimator
    private var styleCache: [SupertonicVoice: Supertonic3VoiceStyle] = [:]

    init(
        manager: Supertonic3Manager, directory: URL?,
        vectorEstimator: Supertonic3VectorEstimator
    ) {
        self.manager = manager
        self.directory = directory
        self.vectorEstimator = vectorEstimator
    }

    /// Downloads the base pack, then eagerly `try?`-fetches every voice style
    /// so "downloaded" means every voice works — same pattern
    /// `KokoroEngineService.ensureModels` uses for Mandarin's roster.
    @discardableResult
    func ensureModels(progressHandler: ProgressHandler?) async throws -> URL {
        let repoDirectory = try await Supertonic3ResourceDownloader.ensureModels(
            directory: directory,
            veVariant: Self.downloadVariantToken(for: vectorEstimator),
            progressHandler: progressHandler)
        for voice in SupertonicVoice.allCases {
            _ = try? await loadVoiceStyle(voice)
        }
        return repoDirectory
    }

    /// Mirrors the SDK's own non-public `Supertonic3VectorEstimator
    /// .downloadVariant` format. Getting it wrong only costs the progress bar
    /// (`initialize()` still fetches whatever is actually missing), but it
    /// would pre-fetch an unused build first.
    private static func downloadVariantToken(for vectorEstimator: Supertonic3VectorEstimator) -> String? {
        switch vectorEstimator {
        case .fp16Dynamic: return nil
        case .dynamic(let quantization): return "dyn-\(quantization.rawValue)"
        case .aneBucketed(let quantization): return "ane-\(quantization.rawValue)"
        }
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    @discardableResult
    func loadVoiceStyle(_ voice: SupertonicVoice) async throws -> Supertonic3VoiceStyle {
        if let cached = styleCache[voice] { return cached }
        let style = try await Supertonic3ResourceDownloader.loadVoiceStyle(
            voice.sdkVoice, directory: directory)
        styleCache[voice] = style
        return style
    }

    func synthesize(text: String, language: String, voice: SupertonicVoice) async throws -> Data {
        let style = try await loadVoiceStyle(voice)
        let result = try await manager.synthesize(text: text, language: language, style: style)
        // Unlike Kokoro (which passes `normalize: false` to match a reference
        // level), this output hasn't been checked by ear yet — revisit if it
        // sounds off.
        return try AudioWAV.data(from: result.samples, sampleRate: Double(Supertonic3Constants.sampleRate))
    }
}
