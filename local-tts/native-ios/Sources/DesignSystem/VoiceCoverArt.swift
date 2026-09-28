import Foundation

/// Resolves a voice's cover image: its own bundled avatar if the catalog
/// says one exists, otherwise a deterministic orb (`OrbCoverArt`). One rule
/// regardless of download state, so callers never branch on availability
/// themselves.
enum VoiceCoverArt {
    static func assetName(for voiceName: String) -> String {
        VoiceCatalog.voice(for: voiceName)?.avatarAssetName
            ?? OrbCoverArt.assetName(for: voiceName)
    }
}
