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
        // FluidAudio's own docs describe Mandarin as shipping a single
        // voice (zf_001) — the same framing they use for English's
        // af_heart, which this app already works around via a bundled
        // conversion (ADR 2). For Mandarin no separate upstream/conversion
        // was needed: all 100 real zf_*/zm_* voice .bin files are already
        // present in FluidAudio's own hosted repo and fetchable through
        // the SDK's own per-voice download path (verified directly over
        // HTTP, not assumed) — see the Mandarin Kokoro plan.
        case .mandarin: return "100 Mandarin voices, ~294MB download"
        }
    }
}
