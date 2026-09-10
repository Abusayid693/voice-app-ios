import FluidAudio
import Foundation

/// Wraps `KokoroAneManager`'s download/init/synthesize calls — the plain
/// async-function surface `TTSViewModel` orchestrates against. No published
/// state lives here; progress is reported back via the caller-supplied
/// closure, matching FluidAudio's own `progressHandler` pattern.
final class KokoroEngineService {
    private let manager: KokoroAneManager
    // Must match the directory `manager` itself was constructed with
    // (DependencyContainer's writable CustomKokoroModel copy) — passing nil
    // here would make ensureModels() check FluidAudio's *default* cache
    // directory instead, which this manager never reads from, and could
    // trigger a spurious network download even though the bundled pack is
    // already present.
    private let directory: URL?

    init(manager: KokoroAneManager, directory: URL?) {
        self.manager = manager
        self.directory = directory
    }

    /// Checks the on-disk cache first — if this engine was already
    /// downloaded in a previous app launch, this returns almost instantly
    /// with no network activity at all, and `progressHandler` never fires.
    func ensureModels(progressHandler: ProgressHandler?) async throws {
        try await KokoroAneResourceDownloader.ensureModels(
            variant: .english, directory: directory, progressHandler: progressHandler)
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice)
    }
}
