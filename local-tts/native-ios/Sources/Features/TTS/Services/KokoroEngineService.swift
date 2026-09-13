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

        try copyBundledMandarinVoices(into: repoDirectory)

        // ensureModels above only guarantees the default voice (zf_001).
        // zm_009 is the only other roster entry FluidAudio's own repo
        // actually hosts (see TTSViewModel.mandarinVoices) — fetch it too
        // so a "downloaded" pack means every listed voice is immediately
        // usable, not one more one-off network fetch happening later. The
        // other 8 names come from copyBundledMandarinVoices above, not
        // the network — FluidAudio's repo doesn't have them.
        _ = try await KokoroAneResourceDownloader.ensureVoicePack(
            "zm_009", repoDirectory: repoDirectory, variant: .mandarin)
        return repoDirectory
    }

    /// Copies hexgrad/Kokoro-82M's 8 officially-named Mandarin voices
    /// (bundled in the app — see `model-conversion/kokoro-mandarin-voices/`
    /// and `docs/adr/0002-custom-kokoro-model-bundle.md`'s bundling
    /// convention) into the downloaded pack's `voices/` folder, the exact
    /// location `KokoroAneManager` looks for a Mandarin voice by name.
    /// Skips any file already present (nothing to do on repeat launches).
    private func copyBundledMandarinVoices(into repoDirectory: URL) throws {
        // Bundle.main.url(forResource:withExtension:subdirectory:) proved
        // unreliable for locating a folder reference on-device elsewhere
        // in this app (silently returns nil — see DependencyContainer's
        // makeKokoroManager()) — build the path directly against the
        // bundle root instead, same fix applied there.
        let bundledDir = Bundle.main.bundleURL.appendingPathComponent("BundledMandarinVoices")
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundledDir.path) else { return }

        let voicesDir = repoDirectory.appendingPathComponent("voices", isDirectory: true)
        if !fm.fileExists(atPath: voicesDir.path) {
            try fm.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        }

        let bundledFiles =
            (try? fm.contentsOfDirectory(at: bundledDir, includingPropertiesForKeys: nil)) ?? []
        for source in bundledFiles where source.pathExtension == "bin" {
            let destination = voicesDir.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try fm.copyItem(at: source, to: destination)
        }
    }

    func initialize() async throws {
        try await manager.initialize()
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice)
    }
}
