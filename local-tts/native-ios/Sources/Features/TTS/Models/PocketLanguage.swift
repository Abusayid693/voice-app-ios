import FluidAudio
import Foundation

/// App-level wrapper around the SDK's `PocketTtsLanguage` — kept separate
/// so app code (Setup, voice picker, cloning) doesn't depend on the SDK
/// enum's exact case names/tiers directly, matching how `Engine` already
/// wraps FluidAudio's own engine concepts elsewhere.
///
/// All 5 cases use the SDK's 6-layer tier — verified byte-identical in
/// size (~527MB each, checked against the exact `v2.1/<lang>/` files this
/// app actually downloads, same files `fetchPocketTtsTotalBytes` already
/// filters to). French is deliberately excluded: the SDK only publishes a
/// 24-layer French pack (no 6-layer tier exists for it at all), which
/// would be a meaningfully bigger, inconsistent download next to these
/// five. See docs/adr/0011-pocket-tts-language-packs.md.
enum PocketLanguage: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case english, german, italian, portuguese, spanish

    var id: Self { self }

    var sdkLanguage: PocketTtsLanguage {
        switch self {
        case .english: return .english
        case .german: return .german
        case .italian: return .italian
        case .portuguese: return .portuguese
        case .spanish: return .spanish
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .spanish: return "Spanish"
        }
    }

    var packTitle: String { "Pocket TTS pack (\(displayName))" }
    var packSubtitle: String { "26 \(displayName) voices, ~527MB download" }
}
