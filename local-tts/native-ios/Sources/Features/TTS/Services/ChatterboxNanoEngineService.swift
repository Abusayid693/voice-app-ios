import FluidAudio
import Foundation

/// Wraps `ChatterboxNanoManager`'s init/synthesize calls — same shape as
/// `KokoroEngineService`/`Supertonic3EngineService`, but the SDK itself
/// differs in two ways this file works around:
/// - There's no separate download-only step: `initialize(progressHandler:)`
///   downloads (if needed) and loads in one idempotent call. `ensureModels`
///   and `initialize` below both just call it.
/// - The manager takes no directory override and returns no resolved URL, so
///   `ensureModels`'s return value is a *computed* path, not one the SDK
///   hands back. See `repoDirectory` below for the risk that carries.
final class ChatterboxNanoEngineService {
    private let manager: ChatterboxNanoManager

    init(manager: ChatterboxNanoManager) {
        self.manager = manager
    }

    @discardableResult
    func ensureModels(progressHandler: ProgressHandler?) async throws -> URL {
        try await manager.initialize(progressHandler: progressHandler)
        return Self.repoDirectory
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    func synthesize(text: String) async throws -> Data {
        let audio = try await manager.synthesize(text: text)
        return try AudioWAV.data(from: audio.samples, sampleRate: Double(audio.sampleRate))
    }

    /// Mirrors the SDK's own *private* `ChatterboxNanoModels.defaultCacheRoot()`
    /// (`TtsCacheDirectory.ensure()` + "Models" + the repo's folder name) —
    /// there's no public API to ask the manager where it actually put things.
    /// If a future FluidAudio revision changes that internal layout, this
    /// silently resolves to the wrong (probably empty) directory rather than
    /// failing loudly — Settings would then just report 0 bytes for this
    /// pack. `Repo.chatterboxNano.folderName` itself is public and read
    /// directly, not hardcoded.
    static var repoDirectory: URL {
        DiskStorage.fluidAudioCacheDirectory
            .appendingPathComponent("Models")
            .appendingPathComponent(Repo.chatterboxNano.folderName)
    }
}
