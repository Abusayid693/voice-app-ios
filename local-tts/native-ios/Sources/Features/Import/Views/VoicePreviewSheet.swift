import SwiftUI

/// Half-height sheet reached by tapping a Trending voices row — large
/// cover art (pulsing with the clip's live audio level while it plays,
/// via TTSViewModel.previewLevel), a progress track, and a play/pause
/// button below it.
struct VoicePreviewSheet: View {
    let tile: VoiceTile
    @ObservedObject var viewModel: TTSViewModel

    private var isPlaying: Bool { viewModel.previewingVoiceID == tile.name }

    var body: some View {
        VStack(spacing: 24) {
            coverArt
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .scaleEffect(isPlaying ? 1 + viewModel.previewLevel * 0.12 : 1)
                .opacity(isPlaying ? 0.85 + viewModel.previewLevel * 0.15 : 1)
                .animation(.easeInOut(duration: 0.12), value: viewModel.previewLevel)
                .padding(.top, 16)

            VStack(spacing: 4) {
                Text(tile.displayName)
                    .font(.title3)
                    .bold()
                    .foregroundStyle(Color.appPrimaryText)
                Text(tile.engineLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.appSecondaryText)
            }

            // The "track" — playback progress for the current clip.
            ProgressView(value: viewModel.previewProgress)
                .tint(Color.appPrimaryText)
                .padding(.horizontal, 40)

            Button {
                viewModel.togglePreview(voiceName: tile.name, engine: tile.engine)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.appPrimaryText)
            }
            .disabled(!tile.isAvailable)

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onDisappear {
            if isPlaying { viewModel.stopPreview() }
        }
    }

    @ViewBuilder
    private var coverArt: some View {
        if tile.isAvailable {
            Image(VoiceCoverArt.assetName(for: tile.name))
                .resizable()
                .scaledToFill()
        } else {
            VoiceCoverArt.placeholderGradient(for: tile.name)
        }
    }
}

#Preview {
    VoicePreviewSheet(
        tile: VoiceTile(
            id: "kokoro-af_heart", name: "af_heart", engine: .kokoroAne, engineLabel: "Kokoro-ANE",
            isAvailable: true),
        viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
