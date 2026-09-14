import Foundation

/// The independently-downloadable voice packs shown in `SetupSheet` — one
/// Kokoro pack per variant (English bundled, Mandarin/Japanese downloaded),
/// one Pocket TTS pack per supported language, and one pack each for
/// Supertonic-3 and Chatterbox Nano (neither has a per-variant/per-language
/// axis — see issues #27 and #30).
enum VoicePack: Identifiable, Equatable {
    case kokoro(KokoroVariant)
    case pocket(PocketLanguage)
    case supertonic3
    case chatterboxNano

    static var allCases: [VoicePack] {
        KokoroVariant.allCases.map { .kokoro($0) } + PocketLanguage.allCases.map { .pocket($0) }
            + [.supertonic3, .chatterboxNano]
    }

    var id: String {
        switch self {
        case .kokoro(let variant): return "kokoro-\(variant.rawValue)"
        case .pocket(let language): return "pocket-\(language.rawValue)"
        case .supertonic3: return "supertonic3"
        case .chatterboxNano: return "chatterbox-nano"
        }
    }

    var title: String {
        switch self {
        case .kokoro(let variant): return variant.packTitle
        case .pocket(let language): return language.packTitle
        case .supertonic3: return "Supertonic-3 pack"
        case .chatterboxNano: return "Chatterbox Nano pack"
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
        // Stated here, not discovered as an error later — see
        // docs/adr/0010-chatterbox-nano-ios18-and-scope.md.
        case .chatterboxNano: return "Expressive voice · short passages only, ~711MB download"
        }
    }
}
