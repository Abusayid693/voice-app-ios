import Foundation

/// The independently-downloadable voice packs shown in `SetupView` — one
/// Kokoro pack per variant (English bundled, Mandarin/Japanese downloaded).
/// A single-case enum since Pocket TTS was removed, kept as an enum because
/// `SetupView`/`VoicePackStore` address packs by `id` and more Kokoro-side
/// pack kinds are plausible.
enum VoicePack: Identifiable, Equatable {
    case kokoro(KokoroVariant)

    static var allCases: [VoicePack] {
        KokoroVariant.allCases.map { .kokoro($0) }
    }

    var id: String {
        switch self {
        case .kokoro(let variant): return "kokoro-\(variant.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .kokoro(let variant): return variant.packTitle
        }
    }

    var subtitle: String {
        switch self {
        case .kokoro(let variant): return variant.packSubtitle
        }
    }
}
