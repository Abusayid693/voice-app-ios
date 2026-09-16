import SwiftUI

/// A compact voice card for a horizontal strip (Voices tab's "Clone
/// voices" row) — avatar + name, tap to preview. Takes primitive fields
/// rather than `ClonedVoice` directly so this stays a DesignSystem
/// component, not one that reaches into `Features/VoiceClone/`.
struct SmallVoiceCard: View {
    let avatarSeed: String
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(OrbCoverArt.assetName(for: avatarSeed))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                Text(name)
                    .appText(.labelStrong)
                    .lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }
}
