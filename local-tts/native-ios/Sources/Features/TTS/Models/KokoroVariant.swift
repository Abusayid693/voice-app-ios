import FluidAudio
import Foundation

/// App-level wrapper around the SDK's `KokoroAneVariant` — kept separate so
/// app code (Setup, voice picker) doesn't depend on the SDK enum's exact
/// case names directly, matching how `PocketLanguage` already wraps
/// `PocketTtsLanguage`.
///
/// Japanese requires FluidAudio pinned past v0.15.7 (see `project.yml`'s
/// `revision:` pin) — `KokoroAneManager.phonemes(for:)` unconditionally
/// threw for it before FluidInference/FluidAudio#915 (merged, not yet in a
/// tagged release) added a real MeCab+Cutlet text frontend.
enum KokoroVariant: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case english, mandarin, japanese

    var id: Self { self }

    var sdkVariant: KokoroAneVariant {
        switch self {
        case .english: return .english
        case .mandarin: return .mandarin
        case .japanese: return .japanese
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .mandarin: return "Mandarin"
        case .japanese: return "Japanese"
        }
    }

    var packTitle: String {
        switch self {
        case .english: return "Kokoro voice pack"
        case .mandarin: return "Kokoro voice pack (Mandarin)"
        case .japanese: return "Kokoro voice pack (Japanese)"
        }
    }

    var packSubtitle: String {
        switch self {
        case .english: return "28 English voices, bundled with the app"
        // 2 voices (zf_001/zm_009) come from FluidAudio's hosted repo at
        // download time; the other 8 (hexgrad's own officially-named
        // Mandarin voices — zf_xiaobei/zm_yunjian/etc.) are bundled in the
        // app already (see TTSViewModel.mandarinVoices), so only the core
        // chain + those 2 voices count toward this download figure.
        case .mandarin: return "10 Mandarin voices, ~242MB download"
        // All 5 voices are FluidAudio's own official roster
        // (KokoroAneConstants.japaneseVoices) and fetch during this
        // download (~85MB: chain + all 5 voices). The Japanese G2P
        // frontend's own assets (~114MB — MeCab dictionary + Cutlet word
        // list) are separate and fetch lazily on the *first* Japanese
        // synthesis, transparently inside the SDK — not part of this
        // number, and not something this app controls or pre-fetches.
        case .japanese: return "5 Japanese voices, ~85MB download (+~114MB on first use)"
        }
    }
}
