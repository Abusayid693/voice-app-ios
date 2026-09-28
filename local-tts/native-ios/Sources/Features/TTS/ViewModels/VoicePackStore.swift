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

    /// Where the bundled English pack lives (nil if the bundled-copy step in
    /// `DependencyContainer` failed) — Settings reports real on-disk sizes.
    let kokoroModelDirectory: URL?
    /// Where the Mandarin pack landed. Unlike English this isn't known up
    /// front, only once a download actually resolves it, and it's deliberately
    /// not persisted: FluidAudio's default-cache-directory logic is private,
    /// so the path can't be recomputed without calling back into the SDK.
    /// Settings shows this pack's size as unknown until Setup runs with
    /// Mandarin selected at least once per launch — the same known
    /// imprecision ADR 7 documents.
    @Published private(set) var kokoroMandarinModelDirectory: URL?

    // MARK: - Download progress

    /// Which pack (`VoicePack.id`) is downloading, if any. `TTSViewModel.isBusy`
    /// is shared across generation and every pack, so Setup's per-row spinner
    /// needs this specific row instead.
    @Published private(set) var downloadingPackID: String?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64?
    /// Set only once a real download event fires. Packs persist on disk across
    /// launches, so `ensureModels()` is cheap and network-free on a fresh
    /// launch even with nothing loaded in memory — gating the download UI on
    /// this avoids showing a fake "Downloading…" for a fast on-disk load.
    @Published private(set) var didDownload = false

    private static let kokoroDownloadedVariantsDefaultsKey = "kokoroDownloadedVariants"

    init(kokoroModelDirectory: URL?, isKokoroPackBundled: Bool) {
        self.kokoroModelDirectory = kokoroModelDirectory
        kokoroDownloadedVariants = Self.loadKokoroDownloadedVariants(bundledEnglish: isKokoroPackBundled)
    }

    // MARK: - Readiness

    /// True if the variant is ready to generate with — bundled (English) or
    /// already downloaded (Mandarin/Japanese).
    func isKokoroPackReady(_ variant: KokoroVariant) -> Bool {
        kokoroDownloadedVariants.contains(variant)
    }

    // MARK: - Recording what's downloaded

    /// Records where a variant's pack resolved to on disk without marking it
    /// downloaded — the generation path resolves this too, but readiness there
    /// was already established before generating.
    func noteModelDirectory(_ directory: URL, for variant: KokoroVariant) {
        guard variant == .mandarin else { return }
        kokoroMandarinModelDirectory = directory
    }

    func markKokoroDownloaded(_ variant: KokoroVariant) {
        kokoroDownloadedVariants.insert(variant)
        UserDefaults.standard.set(
            kokoroDownloadedVariants.map(\.rawValue), forKey: Self.kokoroDownloadedVariantsDefaultsKey)
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
        case .downloading:
            return "Downloading model…"
        case .compiling:
            return "Compiling…"
        }
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
