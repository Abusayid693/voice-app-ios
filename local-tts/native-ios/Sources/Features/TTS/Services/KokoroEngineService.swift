import FluidAudio
import Foundation

/// Wraps `KokoroAneManager`'s download/init/synthesize calls — the plain
/// async-function surface `TTSViewModel` and `ChapterSynthesisService`
/// orchestrate against. No published state lives here; progress is
/// reported back via the caller-supplied closure, matching FluidAudio's
/// own `progressHandler` pattern. `@MainActor` (its only construction site
/// is `TTSViewModel`, already MainActor) so `ensureReady(voice:)` can dedupe
/// concurrent callers with a plain stored `Task` instead of an actor/lock.
@MainActor
final class KokoroEngineService {
    private let manager: KokoroAneManager
    // Must match the directory `manager` itself was constructed with
    // (English: DependencyContainer's writable CustomKokoroModel copy;
    // Mandarin/Japanese: nil, since those managers have no bundled
    // directory) — passing the wrong one here would make ensureModels()
    // check a directory this manager never reads from, and could trigger
    // a spurious network download even though a bundled pack is present.
    private let directory: URL?
    private let variant: KokoroVariant

    init(manager: KokoroAneManager, directory: URL?, variant: KokoroVariant) {
        self.manager = manager
        self.directory = directory
        self.variant = variant
    }

    /// Checks the on-disk cache first — if this engine was already
    /// downloaded in a previous app launch, this returns almost instantly
    /// with no network activity at all, and `progressHandler` never fires.
    /// Returns the resolved repo directory — English already knows its own
    /// (the bundled `directory`), but Mandarin/Japanese don't until this
    /// actually runs, and Settings' Storage page needs the *exact*
    /// directory (not FluidAudio's whole shared cache dir, which other
    /// TTS's languages also share) to report each pack's own size without
    /// double-counting.
    @discardableResult
    func ensureModels(progressHandler: ProgressHandler?) async throws -> URL {
        let repoDirectory = try await KokoroAneResourceDownloader.ensureModels(
            variant: variant.sdkVariant, directory: directory, progressHandler: progressHandler)
        // English's whole 28-voice roster is already bundled from the
        // start (ADR 2) — no per-voice network fetch is ever needed or
        // useful for it.
        guard variant != .english else { return repoDirectory }

        if variant == .mandarin {
            try copyBundledMandarinVoices(into: repoDirectory)
        }

        // The base ensureModels call above only guarantees the variant's
        // own documented default voice. Eagerly fetch the rest of this
        // app's roster (TTSViewModel.kokoroVoices(for:)) too, so a
        // "downloaded" pack means every listed voice is immediately
        // usable rather than one-off network fetches happening later, the
        // first time each voice gets picked. `try?`, not `try await`: a
        // name this can't fetch (Mandarin's 8 bundled voices, already
        // copied in above — FluidAudio's repo doesn't host them under
        // those names) or a transient network hiccup on one voice
        // shouldn't fail the whole pack download over an already-optional
        // extra.
        let defaultVoice = variant.sdkVariant.defaultVoice
        for name in TTSViewModel.kokoroVoices(for: variant) where name != defaultVoice {
            _ = try? await KokoroAneResourceDownloader.ensureVoicePack(
                name, repoDirectory: repoDirectory, variant: variant.sdkVariant)
        }
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

    /// - Parameter preloadVoice: loaded up front when given. Without it the
    ///   manager defers the voice pack to the first `synthesize()` call
    ///   (`KokoroAneManager.runChain` → `store.voicePack`), so the user pays
    ///   for it on their first Generate instead of during preparation.
    func initialize(preloadVoice: String? = nil) async throws {
        try await manager.initialize(preloadVoices: preloadVoice.map { [$0] })
    }

    /// Runs one throwaway synthesis purely for its side effect: CoreML
    /// defers ANE specialization to the first real `prediction()`, so
    /// loading the models isn't enough to make the first Generate fast.
    /// The audio is discarded and never played.
    func warmUpInference(voice: String) async throws {
        _ = try await manager.synthesize(text: "Hello", voice: voice)
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        try await manager.synthesize(text: text, voice: voice)
    }

    // Exposes inputIds/predictedDurations for word-level timing derivation
    // (see ChapterSynthesisService) — synthesize() discards these.
    func synthesizeDetailed(text: String, voice: String) async throws -> KokoroAneSynthesisResult {
        try await manager.synthesizeDetailed(text: text, voice: voice)
    }

    private var phonemeGroupCountCache: [String: Int] = [:]

    /// How many space-separated phoneme groups one normalized word
    /// produces — used by WordTimingDeriver to know how many of the real
    /// synthesis's token groups a displayed word should consume. Memoized:
    /// real text repeats words heavily, and the SDK itself has no cache for
    /// this (only for in-lexicon G2P lookups, not the string wrapping this
    /// method does around them).
    func phonemeGroupCount(for word: String) async -> Int {
        if let cached = phonemeGroupCountCache[word] { return cached }
        let count: Int
        if let phonemeString = try? await manager.phonemes(for: word) {
            count = max(1, phonemeString.split(separator: " ").count)
        } else {
            count = 1
        }
        phonemeGroupCountCache[word] = count
        return count
    }

    private var cachedSpaceTokenId: Int32?

    /// The vocab id for `" "` — the token `inputIds` uses to separate
    /// words, per WordTimingDeriver's grouping. Loaded from the same
    /// `directory` this manager itself reads its models/vocab from
    /// (English only; Mandarin/Japanese managers have no bundled
    /// `directory` and word-level timing isn't attempted for them).
    func spaceTokenId() throws -> Int32 {
        if let cached = cachedSpaceTokenId { return cached }
        guard let directory else { throw KokoroEngineServiceError.noModelDirectory }
        let vocabURL = directory.appendingPathComponent("kokoro-82m-coreml/ANE/vocab.json")
        let vocab = try KokoroAneVocab.load(from: vocabURL)
        guard let id = vocab.map[" "] else { throw KokoroEngineServiceError.noSpaceToken }
        cachedSpaceTokenId = id
        return id
    }

    private var readyTask: Task<Void, Error>?
    private var preloadedVoice: String?

    /// Ensures models are downloaded, initialized, and this voice's pack is
    /// loaded — deduped so two concurrent reader requests never run
    /// `ensureModels()`/`initialize()` twice at once. Safe to call
    /// repeatedly; a second call for the same already-loaded voice returns
    /// immediately once the in-flight task finishes.
    func ensureReady(voice: String, progressHandler: ProgressHandler? = nil) async throws {
        if let readyTask {
            try await readyTask.value
            if preloadedVoice == voice { return }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.ensureModels(progressHandler: progressHandler)
            try await self.initialize(preloadVoice: voice)
        }
        readyTask = task
        try await task.value
        preloadedVoice = voice
    }

    enum KokoroEngineServiceError: Error {
        case noModelDirectory
        case noSpaceToken
    }
}
