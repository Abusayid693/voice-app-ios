import Hugeicons
import SwiftUI

/// One voice's row in Trending voices: cover image, name, a short persona
/// tagline, and a trailing play/pause indicator (reflects whether this
/// voice's preview is the one currently playing, started from
/// VoicePreviewSheet). The whole card is the tap target — tapping opens
/// VoicePreviewSheet.
struct PreviewVoiceCard: View {
    let tile: VoiceTile
    @ObservedObject var previewPlayer: VoicePreviewPlayer
    let onTap: () -> Void

    private var isPreviewing: Bool { previewPlayer.playingVoiceID == tile.name }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 10) {
                avatar
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(tile.displayName).appText(.cardTitle)
                        .lineLimit(1)
                    Text(tile.descriptionText).appText(.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                (isPreviewing ? Hugeicons.pause : Hugeicons.play)
                    .image()
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.appTertiaryText)
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 14)
            .frame(width: 310)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tile.isAvailable)
        .opacity(tile.isAvailable ? 1 : 0.6)
    }

    private var avatar: some View {
        Image(VoiceCoverArt.assetName(for: tile.name))
            .resizable()
            .scaledToFill()
    }
}
