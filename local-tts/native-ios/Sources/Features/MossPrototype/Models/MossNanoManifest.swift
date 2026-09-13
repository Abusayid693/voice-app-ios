import Foundation

/// Mirrors the fields this app actually reads from `browser_poc_manifest.json`
/// — OpenMOSS's own top-level manifest for MOSS-TTS-Nano's ONNX pipeline
/// (ships inside `OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX`). Structural token
/// IDs, prompt-row templates, and the bundled reference-voice audio codes
/// voice cloning splices in — verified against OpenMOSS's own Android ONNX
/// reference implementation (`examples/android_onnx_runtime/.../
/// MossOnnxDemoEngine.kt`), which this whole feature is ported from.
/// `model_files` (only relevant for locating files on that demo's own disk
/// layout — this app controls its own layout via `MossNanoModelDownloader`)
/// is deliberately not declared; `Decodable` ignores unrecognized keys.
struct MossNanoManifest: Decodable {
    let ttsConfig: TtsConfig
    let promptTemplates: PromptTemplates
    let generationDefaults: GenerationDefaults
    let builtinVoices: [BuiltinVoice]

    enum CodingKeys: String, CodingKey {
        case ttsConfig = "tts_config"
        case promptTemplates = "prompt_templates"
        case generationDefaults = "generation_defaults"
        case builtinVoices = "builtin_voices"
    }

    struct TtsConfig: Decodable {
        let nVq: Int
        let audioPadTokenId: Int
        let audioStartTokenId: Int
        let audioEndTokenId: Int
        let audioUserSlotTokenId: Int
        let audioAssistantSlotTokenId: Int
        let audioCodebookSizes: [Int]

        enum CodingKeys: String, CodingKey {
            case nVq = "n_vq"
            case audioPadTokenId = "audio_pad_token_id"
            case audioStartTokenId = "audio_start_token_id"
            case audioEndTokenId = "audio_end_token_id"
            case audioUserSlotTokenId = "audio_user_slot_token_id"
            case audioAssistantSlotTokenId = "audio_assistant_slot_token_id"
            case audioCodebookSizes = "audio_codebook_sizes"
        }
    }

    struct PromptTemplates: Decodable {
        let userPromptPrefixTokenIds: [Int]
        let userPromptAfterReferenceTokenIds: [Int]
        let assistantPromptPrefixTokenIds: [Int]

        enum CodingKeys: String, CodingKey {
            case userPromptPrefixTokenIds = "user_prompt_prefix_token_ids"
            case userPromptAfterReferenceTokenIds = "user_prompt_after_reference_token_ids"
            case assistantPromptPrefixTokenIds = "assistant_prompt_prefix_token_ids"
        }
    }

    struct GenerationDefaults: Decodable {
        let maxNewFrames: Int
        enum CodingKeys: String, CodingKey { case maxNewFrames = "max_new_frames" }
    }

    /// `promptAudioCodes` is a `[frame][codebook]` grid of pre-tokenized RVQ
    /// codes for one built-in reference voice — this prototype always uses
    /// the first voice that has any (matching the Android demo's own
    /// fallback), rather than exposing a voice picker yet.
    struct BuiltinVoice: Decodable {
        let voice: String
        let promptAudioCodes: [[Int]]
        enum CodingKeys: String, CodingKey {
            case voice
            case promptAudioCodes = "prompt_audio_codes"
        }
    }
}

/// Mirrors the fields read from `tts_browser_onnx_meta.json` (ships
/// alongside the manifest above) — the exact ONNX tensor names the KV-cache
/// decode loop threads between calls. Verified directly against the real
/// file, not guessed.
struct MossNanoTtsMeta: Decodable {
    let onnx: OnnxNames

    struct OnnxNames: Decodable {
        let decodeInputNames: [String]
        let decodeOutputNames: [String]

        enum CodingKeys: String, CodingKey {
            case decodeInputNames = "decode_input_names"
            case decodeOutputNames = "decode_output_names"
        }
    }
}

/// Mirrors `codec_browser_onnx_meta.json` (ships inside
/// `OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX`).
struct MossNanoCodecMeta: Decodable {
    let codecConfig: CodecConfig

    struct CodecConfig: Decodable {
        let sampleRate: Int
        enum CodingKeys: String, CodingKey { case sampleRate = "sample_rate" }
    }

    enum CodingKeys: String, CodingKey {
        case codecConfig = "codec_config"
    }
}
