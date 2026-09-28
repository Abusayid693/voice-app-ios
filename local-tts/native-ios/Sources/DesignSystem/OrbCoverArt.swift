import SwiftUI

/// Orb-style fallback cover art — used wherever a voice has no real image,
/// e.g. VoicesTabView's grid/VoicePreviewSheet cards for voices whose pack
/// isn't downloaded yet. One deterministic-by-name lookup shared across all
/// of them, same pattern as `VoiceCoverArt.assetName(for:)`
/// (`DesignSystem/VoiceCoverArt.swift`): the same seed always yields the
/// same orb, so it doesn't flicker to a different one on every redraw.
enum OrbCoverArt {
    // Key-value mapping of orb asset names — grows as more orb variants are
    // generated (see assets/orbs/ for the source exports).
    private static let assetNames = [
        "VoiceOrb1", "VoiceOrb2", "VoiceOrb3", "VoiceOrb4", "VoiceOrb5", "VoiceOrb6", "VoiceOrb7",
        "VoiceOrb8",
    ]

    static func assetName(for seed: String) -> String {
        let sum = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return assetNames[sum % assetNames.count]
    }
}
