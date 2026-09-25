import Foundation

/// Best-effort "total download size" lookups for the voice packs, read from
/// HuggingFace's public tree API. The SDK's own progress callback reports a
/// fraction, not byte totals, so these exist purely to label the progress UI.
enum VoicePackSizeService {
    /// Sums a Kokoro-ANE variant's bundle (`ANE` / `ANE-zh` / `ANE-ja`).
    /// Mandarin slightly overcounts (includes FluidAudio's full 100-voice
    /// `voices/` folder, of which only 2 are fetched); Japanese overcounts
    /// more (includes the ~114MB `assets/` G2P folder, fetched lazily on
    /// first synthesis, not by `ensureModels`). Acceptable for a progress
    /// display, not worth a second per-file lookup.
    static func kokoroTotalBytes(variant: KokoroVariant) async -> Int64? {
        let subdirectory: String
        switch variant {
        case .english: subdirectory = "ANE"
        case .mandarin: subdirectory = "ANE-zh"
        case .japanese: subdirectory = "ANE-ja"
        }
        return await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url:
                "https://huggingface.co/api/models/FluidInference/kokoro-82m-coreml/tree/main/\(subdirectory)?recursive=true",
            matching: { _ in true })
    }
}
