import LucideSwift
import SwiftUI

/// A voice's full-width row (Voices tab's "Your voices" list) — avatar,
/// name/subtitle, and a trailing play/pause (or loading) button. Takes
/// primitive fields rather than `ClonedVoice` directly so this stays a
/// DesignSystem component, not one that reaches into
/// `Features/VoiceClone/`.
struct VoiceCard: View {
    let avatarSeed: String
    let name: String
    let subtitle: String
    let isPlaying: Bool
    let isLoading: Bool
    let onPlayToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(OrbCoverArt.assetName(for: avatarSeed))
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(name).appText(.rowTitle)
                Text(subtitle).appText(.label)
            }

            Spacer()

            Button(action: onPlayToggle) {
                if isLoading {
                    ProgressView()
                } else {
                    LucideIcon(isPlaying ? .circlePause : .circlePlay, size: 22, color: Color.appPrimaryText)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
