import Foundation

/// The independently-downloadable voice packs shown in `SetupView` — one
/// Kokoro pack per variant (English bundled, Mandarin/Japanese downloaded)
/// and one Pocket TTS pack per supported language.
enum VoicePack: Identifiable, Equatable {
    case kokoro(KokoroVariant)
    case pocket(PocketLanguage)

    static var allCases: [VoicePack] {
        KokoroVariant.allCases.map { .kokoro($0) } + PocketLanguage.allCases.map { .pocket($0) }
    }

    var id: String {
        switch self {
        case .kokoro(let variant): return "kokoro-\(variant.rawValue)"
        case .pocket(let language): return "pocket-\(language.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .kokoro(let variant): return variant.packTitle
        case .pocket(let language): return language.packTitle
        }
    }

    var subtitle: String {
        switch self {
        case .kokoro(let variant): return variant.packSubtitle
        case .pocket(let language): return language.packSubtitle
        }
    }
}
