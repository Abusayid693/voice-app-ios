import FluidAudio
import Foundation

/// Wraps `KokoroAneManager`'s download/init/synthesize calls — the plain
/// async-function surface `TTSViewModel` orchestrates against. No published
/// state lives here; progress is reported back via the caller-supplied
/// closure, matching FluidAudio's own `progressHandler` pattern.
final class KokoroEngineService {
    private let manager: KokoroAneManager
    // Must match the directory `manager` itself was constructed with
    // (English: DependencyContainer's writable CustomKokoroModel copy;
    // Mandarin: nil, since that manager has no bundled directory) —
    // passing the wrong one here would make ensureModels() check a
    // directory this manager never reads from, and could trigger a
    // spurious network download even though a bundled pack is present.
    private let directory: URL?
    private let variant: KokoroAneVariant

    init(manager: KokoroAneManager, directory: URL?, variant: KokoroAneVariant) {
        self.manager = manager
        self.directory = directory
        self.variant = variant
    }

    /// Checks the on-disk cache first — if this engine was already
    /// downloaded in a previous app launch, this returns almost instantly
    /// with no network activity at all, and `progressHandler` never fires.
    /// Returns the resolved repo directory — English already knows its own
    /// (the bundled `directory`), but Mandarin doesn't until this actually
    /// runs, and Settings' Storage page needs the *exact* directory (not
    /// FluidAudio's whole shared cache dir, which Pocket TTS's languages
    /// also share) to report Mandarin's own size without double-counting.
    @discardableResult
    func ensureModels(progressHandler: ProgressHandler?) async throws -> URL {
        let repoDirectory = try await KokoroAneResourceDownloader.ensureModels(
            variant: variant, directory: directory, progressHandler: progressHandler)
        guard variant == .mandarin else { return repoDirectory }
        // ensureModels above only guarantees the default voice
        // (zf_001) — fetch the rest of the roster too, so a "downloaded"
        // Mandarin pack means every voice is immediately usable rather
        // than 99 more one-off network fetches happening later, the first
        // time each voice gets picked. Cheap: ~522KB each, ~52MB total.
        // No per-file progress reporting here (ensureVoicePack doesn't
        // expose any) — the visible progress bar finishes at the main
        // chain download and this tail runs quietly after.
        for name in TTSViewModel.mandarinVoices where name != KokoroAneConstants.defaultVoiceMandarin {
            _ = try await KokoroAneResourceDownloader.ensureVoicePack(
                name, repoDirectory: repoDirectory, variant: .mandarin)
        }
        return repoDirectory
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice)
    }
}
