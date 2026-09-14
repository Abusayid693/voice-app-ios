import FluidAudio
import Foundation

/// App-level wrapper around the SDK's `Supertonic3Voice`, matching how
/// `KokoroVariant`/`PocketLanguage` wrap theirs. These 10 are fixed
/// speaker-style presets with no language baked in — the same voice speaks
/// any `SupertonicLanguage`, chosen independently at synthesis time.
enum SupertonicVoice: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case f1, f2, f3, f4, f5, m1, m2, m3, m4, m5

    static let `default`: SupertonicVoice = .m1

    var id: Self { self }

    var sdkVoice: Supertonic3Voice {
        switch self {
        case .f1: return .f1
        case .f2: return .f2
        case .f3: return .f3
        case .f4: return .f4
        case .f5: return .f5
        case .m1: return .m1
        case .m2: return .m2
        case .m3: return .m3
        case .m4: return .m4
        case .m5: return .m5
        }
    }

    var displayName: String { "Voice \(rawValue.uppercased())" }
}
