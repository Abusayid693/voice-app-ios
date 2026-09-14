import FluidAudio
import Foundation

/// Which voice packs are on disk, where they live, and the progress of the
/// one currently downloading.
///
/// Split out of `TTSViewModel`, which owned this alongside generation and
/// playback. It stays a separate observable object rather than more state
/// there because the two have no overlap: nothing in generation reads pack
/// inventory, and the screens that read inventory (Setup, Settings' Voice
/// Packs/Storage, Import's tile availability) never touch generation.
///
/// Deliberately does *not* own `status`/`isBusy` — those are shared with
/// generation, so they stay on `TTSViewModel`, which orchestrates a download
/// and translates what happens here into them.
@MainActor
final class VoicePackStore: ObservableObject {
    // MARK: - Inventory

    @Published private(set) var kokoroDownloadedVariants: Set<KokoroVariant> = []
    @Published private(set) var pocketDownloadedLanguages: Set<PocketLanguage> = []

    /// Where the bundled English pack lives (nil if the bundled-copy step in
    /// `DependencyContainer` failed) — Settings reports real on-disk sizes.
    let kokoroModelDirectory: URL?
    /// Where the Mandarin pack landed. Unlike English this isn't known up
    /// front, only once a download actually resolves it, and it's deliberately
    /// not persisted: FluidAudio's default-cache-directory logic is private,
    /// so the path can't be recomputed without calling back into the SDK.
    /// Settings shows this pack's size as unknown until Setup or Write runs
    /// with Mandarin selected at least once per launch — the same known
    /// imprecision ADR 7 documents for Pocket TTS.
    @Published private(set) var kokoroMandarinModelDirectory: URL?

    /// A single bool, not a Set — one Supertonic-3 pack covers all 31
    /// languages and all 10 voices (see `VoicePack.supertonic3`).
    @Published private(set) var isSupertonic3Downloaded = false
    /// Resolved the same way (and with the same caveat) as
    /// `kokoroMandarinModelDirectory`. Kept separate from Pocket's
    /// whole-shared-cache measurement so Storage doesn't count it twice.
    @Published private(set) var supertonic3ModelDirectory: URL?

    /// Same shape as `isSupertonic3Downloaded` — one Chatterbox Nano pack,
    /// no per-variant axis (see `VoicePack.chatterboxNano`).
    @Published private(set) var isChatterboxNanoDownloaded = false
    @Published private(set) var chatterboxNanoModelDirectory: URL?

    // MARK: - Download progress

    /// Which pack (`VoicePack.id`) is downloading, if any. `TTSViewModel.isBusy`
    /// is shared across generation and every pack, so Setup's per-row spinner
    /// needs this specific row instead.
    @Published private(set) var downloadingPackID: String?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64?
    /// "3 / 47" file counter, when the SDK is in its downloading phase.
    @Published private(set) var fileProgress: String?
    /// Set only once a real download event fires. Packs persist on disk across
    /// launches, so `ensureModels()` is cheap and network-free on a fresh
    /// launch even with nothing loaded in memory — gating the download UI on
    /// this avoids showing a fake "Downloading…" for a fast on-disk load.
    @Published private(set) var didDownload = false

    private static let kokoroDownloadedVariantsDefaultsKey = "kokoroDownloadedVariants"
    private static let pocketPackDownloadedLanguagesDefaultsKey = "pocketPackDownloadedLanguages"
    // Original single-language flag, kept only to migrate existing installs.
    private static let legacyPocketPackDownloadedBoolKey = "pocketPackDownloaded"
    private static let supertonic3DownloadedDefaultsKey = "supertonic3Downloaded"
    private static let chatterboxNanoDownloadedDefaultsKey = "chatterboxNanoDownloaded"

    init(kokoroModelDirectory: URL?, isKokoroPackBundled: Bool) {
        self.kokoroModelDirectory = kokoroModelDirectory
        kokoroDownloadedVariants = Self.loadKokoroDownloadedVariants(bundledEnglish: isKokoroPackBundled)
        pocketDownloadedLanguages = Self.loadPocketDownloadedLanguages()
        isSupertonic3Downloaded = UserDefaults.standard.bool(forKey: Self.supertonic3DownloadedDefaultsKey)
        isChatterboxNanoDownloaded = UserDefaults.standard.bool(
            forKey: Self.chatterboxNanoDownloadedDefaultsKey)
    }

    // MARK: - Readiness

    /// True if the variant is ready to generate with — bundled (English) or
    /// already downloaded (Mandarin/Japanese).
    func isKokoroPackReady(_ variant: KokoroVariant) -> Bool {
        kokoroDownloadedVariants.contains(variant)
    }

    func isPocketPackDownloaded(_ language: PocketLanguage) -> Bool {
        pocketDownloadedLanguages.contains(language)
    }

    /// Convenience for call sites that predate multi-variant/multi-language
    /// support and only ever meant the original English pack.
    var isKokoroPackReady: Bool { isKokoroPackReady(.english) }
    var isPocketPackDownloaded: Bool { isPocketPackDownloaded(.english) }

    // MARK: - Recording what's downloaded

    /// Records where a variant's pack resolved to on disk without marking it
    /// downloaded — the generation path resolves this too, but readiness there
    /// was already established before generating.
    func noteModelDirectory(_ directory: URL, for variant: KokoroVariant) {
        guard variant == .mandarin else { return }
        kokoroMandarinModelDirectory = directory
    }

    /// Same idea as `noteModelDirectory(_:for:)`, for the one Supertonic-3
    /// pack — called separately from `markSupertonic3Downloaded()` so the
    /// generation path (which resolves the directory but shouldn't mark the
    /// pack "downloaded" for Setup-UI purposes) can still record it.
    func noteSupertonic3ModelDirectory(_ directory: URL) {
        supertonic3ModelDirectory = directory
    }

    func noteChatterboxNanoModelDirectory(_ directory: URL) {
        chatterboxNanoModelDirectory = directory
    }

    func markKokoroDownloaded(_ variant: KokoroVariant) {
        kokoroDownloadedVariants.insert(variant)
        UserDefaults.standard.set(
            kokoroDownloadedVariants.map(\.rawValue), forKey: Self.kokoroDownloadedVariantsDefaultsKey)
    }

    func markPocketDownloaded(_ language: PocketLanguage) {
        pocketDownloadedLanguages.insert(language)
        UserDefaults.standard.set(
            pocketDownloadedLanguages.map(\.rawValue),
            forKey: Self.pocketPackDownloadedLanguagesDefaultsKey)
    }

    func markSupertonic3Downloaded() {
        isSupertonic3Downloaded = true
        UserDefaults.standard.set(true, forKey: Self.supertonic3DownloadedDefaultsKey)
    }

    func markChatterboxNanoDownloaded() {
        isChatterboxNanoDownloaded = true
        UserDefaults.standard.set(true, forKey: Self.chatterboxNanoDownloadedDefaultsKey)
    }

    private static func loadKokoroDownloadedVariants(bundledEnglish: Bool) -> Set<KokoroVariant> {
        var variants: Set<KokoroVariant> = []
        if let rawValues = UserDefaults.standard.array(forKey: kokoroDownloadedVariantsDefaultsKey)
            as? [String]
        {
            variants = Set(rawValues.compactMap(KokoroVariant.init(rawValue:)))
        }
        // English doesn't rely on persistence — it's ready the instant the
        // bundled copy succeeds, every launch.
        if bundledEnglish { variants.insert(.english) }
        return variants
    }

    private static func loadPocketDownloadedLanguages() -> Set<PocketLanguage> {
        let defaults = UserDefaults.standard
        if let rawValues = defaults.array(forKey: pocketPackDownloadedLanguagesDefaultsKey) as? [String] {
            return Set(rawValues.compactMap(PocketLanguage.init(rawValue:)))
        }
        // Pre-multi-language installs only ever had English — migrate the old
        // bool so those users don't lose an already-downloaded pack.
        return defaults.bool(forKey: legacyPocketPackDownloadedBoolKey) ? [.english] : []
    }

    // MARK: - Progress

    func beginDownload(packID: String) {
        downloadingPackID = packID
    }

    func endDownload() {
        downloadingPackID = nil
    }

    /// Applies one SDK progress event and returns the status label for it.
    /// The label is returned rather than assigned because `status` is shared
    /// with generation and stays on `TTSViewModel`.
    func apply(
        _ progress: DownloadProgress, phaseWeight: Double,
        fetchTotal: @escaping () async -> Int64?
    ) -> String {
        if !didDownload {
            didDownload = true
            Task { @MainActor in totalBytes = await fetchTotal() }
        }
        fraction = min(1, progress.fractionCompleted / phaseWeight)
        if let totalBytes {
            downloadedBytes = Int64(fraction * Double(totalBytes))
        }
        switch progress.phase {
        case .listing:
            return "Listing model files…"
        case .downloading(let completedFiles, let totalFiles):
            fileProgress = "\(completedFiles) / \(totalFiles)"
            return "Downloading model…"
        case .compiling:
            return "Compiling…"
        }
    }

    func resetProgress() {
        fraction = 0
        downloadedBytes = 0
        totalBytes = nil
        fileProgress = nil
        didDownload = false
    }

    var progressLabel: String {
        let downloaded = Self.formatMB(downloadedBytes)
        guard let totalBytes else { return "\(downloaded) MB" }
        return "\(downloaded) / \(Self.formatMB(totalBytes)) MB"
    }

    private static func formatMB(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }
}
