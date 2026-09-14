import FluidAudio
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

    /// Same idea for a PocketTTS language pack — but that directory also holds
    /// the GPU/int8 variants, the MLState package and the uncompiled
    /// `.mlpackage` sources, none of which `ensureModels(placement: .ane)`
    /// downloads. Filtering to the components it actually fetches keeps the
    /// total honest.
    static func pocketTotalBytes(language: PocketLanguage) async -> Int64? {
        // `sdkLanguage.rawValue` matches the real v2.1/<name>/ folder name for
        // every case — verified against the HuggingFace listing, not assumed.
        // All five came back the same size (~527MB) under this filter, see
        // docs/adr/0011-pocket-tts-language-packs.md.
        let langPath = language.sdkLanguage.rawValue
        let required = [
            "v2.1/\(langPath)/cond_prefill_ane.mlmodelc/",
            "v2.1/\(langPath)/flowlm_step_ane.mlmodelc/",
            "v2.1/\(langPath)/flow_decoder_fused.mlmodelc/",
            "v2.1/\(langPath)/mimi_decoder.mlmodelc/",
            "v2.1/\(langPath)/constants_bin/",
        ]
        return await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url:
                "https://huggingface.co/api/models/FluidInference/pocket-tts-coreml/tree/main/v2.1/\(langPath)?recursive=true",
            matching: { path in required.contains { path.hasPrefix($0) } })
    }

    /// Same idea for the Supertonic-3 pack — the repo root also holds the
    /// `.mlpackage` (uncompiled) sources, every other VectorEstimator
    /// quantization/bucket build, and per-voice `.json` style files under
    /// `voice_styles/`. Filtered to exactly what
    /// `Supertonic3EngineService.ensureModels` fetches: the 3 shared stages,
    /// the config files, the 3 ANE-bucketed int4 VectorEstimator builds
    /// (`Supertonic3EngineService.vectorEstimator`'s default), and all 10
    /// voice styles (fetched eagerly, same "complete the roster" pattern as
    /// Kokoro's Mandarin voices). Verified directly against the live tree —
    /// ~164MB total, not the ~398MB figure in issue #27 (that's for a
    /// different, larger VectorEstimator build).
    static func supertonic3TotalBytes() async -> Int64? {
        let required = [
            "TextEncoder.mlmodelc/",
            "DurationPredictor.mlmodelc/",
            "Vocoder.mlmodelc/",
            "tts.json",
            "unicode_indexer.json",
            "VectorEstimatorVariants/VectorEstimator_L128_int4.mlmodelc/",
            "VectorEstimatorVariants/VectorEstimator_L256_int4.mlmodelc/",
            "VectorEstimatorVariants/VectorEstimator_L512_int4.mlmodelc/",
            "voice_styles/",
        ]
        return await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url:
                "https://huggingface.co/api/models/FluidInference/supertonic-3-coreml/tree/main?recursive=true",
            matching: { path in required.contains { path.hasPrefix($0) || path == $0 } })
    }

    /// Same idea for the Chatterbox Nano pack. Unlike Supertonic-3/Pocket,
    /// the SDK's own required-file list (`ModelNames.ChatterboxNano`) is
    /// public, so this reads it directly instead of hand-duplicating it —
    /// the repo root also holds every `.mlpackage` (uncompiled) source and
    /// a non-stateful decode variant, neither of which `ensureModels` fetches.
    static func chatterboxNanoTotalBytes() async -> Int64? {
        let modelDirs = ModelNames.ChatterboxNano.requiredModels.map { "\($0)/" }
        let auxFiles = ModelNames.ChatterboxNano.auxFiles
        return await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url:
                "https://huggingface.co/api/models/FluidInference/chatterbox-nano-coreml/tree/main?recursive=true",
            matching: { path in
                modelDirs.contains { path.hasPrefix($0) } || auxFiles.contains(path)
            })
    }
}
