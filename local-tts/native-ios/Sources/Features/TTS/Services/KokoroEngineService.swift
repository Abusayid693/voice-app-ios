import FluidAudio
import Foundation

/// Wraps `KokoroAneManager`'s download/init/synthesize calls — the plain
/// async-function surface `TTSViewModel` orchestrates against. No published
/// state lives here; progress is reported back via the caller-supplied
/// closure, matching FluidAudio's own `progressHandler` pattern.
final class KokoroEngineService {
    private let manager: KokoroAneManager

    init(manager: KokoroAneManager) {
        self.manager = manager
    }

    /// Checks the on-disk cache first — if this engine was already
    /// downloaded in a previous app launch, this returns almost instantly
    /// with no network activity at all, and `progressHandler` never fires.
    func ensureModels(progressHandler: ProgressHandler?) async throws {
        try await KokoroAneResourceDownloader.ensureModels(
            variant: .english, progressHandler: progressHandler)
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice)
    }
}
