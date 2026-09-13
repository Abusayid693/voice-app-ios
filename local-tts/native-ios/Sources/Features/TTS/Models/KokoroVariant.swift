import FluidAudio
import Foundation

/// App-level wrapper around the SDK's `KokoroAneVariant` — kept separate so
/// app code (Setup, voice picker) doesn't depend on the SDK enum's exact
/// case names directly, matching how `PocketLanguage` already wraps
/// `PocketTtsLanguage`.
///
/// Japanese is deliberately excluded: `KokoroAneManager.phonemes(for:)`
/// unconditionally throws for it today — no text G2P frontend exists (see
/// FluidInference/FluidAudio#914). A pack for a variant that can't accept
/// typed text isn't useful yet.
enum KokoroVariant: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case english, mandarin

    var id: Self { self }

    var sdkVariant: KokoroAneVariant {
        switch self {
        case .english: return .english
        case .mandarin: return .mandarin
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .mandarin: return "Mandarin"
        }
    }

    var packTitle: String {
        switch self {
        case .english: return "Kokoro voice pack"
        case .mandarin: return "Kokoro voice pack (Mandarin)"
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
        }
    }
}
