import Foundation

/// The independently-downloadable voice packs shown in `SetupSheet` —
/// Kokoro (one, bundled) plus one Pocket TTS pack per supported language.
enum VoicePack: Identifiable, Equatable {
    case kokoro
    case pocket(PocketLanguage)

    static var allCases: [VoicePack] {
        [.kokoro] + PocketLanguage.allCases.map { .pocket($0) }
    }

    var id: String {
        switch self {
        case .kokoro: return "kokoro"
        case .pocket(let language): return "pocket-\(language.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .kokoro: return "Kokoro voice pack"
        case .pocket(let language): return language.packTitle
        }
    }

    var subtitle: String {
        switch self {
        case .kokoro: return "28 English voices, bundled with the app"
        case .pocket(let language): return language.packSubtitle
        }
    }
}
