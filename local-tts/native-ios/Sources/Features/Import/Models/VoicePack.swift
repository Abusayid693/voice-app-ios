import Foundation

/// The two independently-downloadable voice packs shown in `SetupSheet`.
enum VoicePack: CaseIterable, Identifiable {
    case kokoro
    case pocket

    var id: Self { self }

    var title: String {
        switch self {
        case .kokoro: return "Kokoro voice pack"
        case .pocket: return "Pocket TTS pack"
        }
    }

    var subtitle: String {
        switch self {
        case .kokoro: return "28 English voices, bundled with the app"
        case .pocket: return "26 English voices, ~500MB download"
        }
    }
}
