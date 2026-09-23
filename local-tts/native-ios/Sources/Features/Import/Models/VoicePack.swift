import Foundation

/// The independently-downloadable voice packs shown in `SetupView` — one
/// Kokoro pack per variant (English bundled, Mandarin/Japanese downloaded),
/// one Pocket TTS pack per supported language, and one Supertonic-3 pack
/// (unlike the other two, it has no per-variant/per-language axis: its
/// base model plus all 10 voice styles come down together — see issue #27).
enum VoicePack: Identifiable, Equatable {
    case kokoro(KokoroVariant)
    case pocket(PocketLanguage)
    case supertonic3

    static var allCases: [VoicePack] {
        KokoroVariant.allCases.map { .kokoro($0) } + PocketLanguage.allCases.map { .pocket($0) }
            + [.supertonic3]
    }

    var id: String {
        switch self {
        case .kokoro(let variant): return "kokoro-\(variant.rawValue)"
        case .pocket(let language): return "pocket-\(language.rawValue)"
        case .supertonic3: return "supertonic3"
        }
    }

    var title: String {
        switch self {
        case .kokoro(let variant): return variant.packTitle
        case .pocket(let language): return language.packTitle
        case .supertonic3: return "Supertonic-3 pack"
        }
    }

    var subtitle: String {
        switch self {
        case .kokoro(let variant): return variant.packSubtitle
        case .pocket(let language): return language.packSubtitle
        // ~164MB verified directly against HuggingFace's tree API for the
        // exact files `ensureModels` fetches at the SDK's own recommended
        // iOS config (.aneBucketed(.int4)) — not the ~398MB figure in
        // issue #27, which is for a different (fp16Dynamic) build.
        case .supertonic3: return "31 languages · 10 voices, ~164MB download"
        }
    }
}
