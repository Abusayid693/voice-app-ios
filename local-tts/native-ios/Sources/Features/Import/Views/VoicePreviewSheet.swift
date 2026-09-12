import LucideSwift
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
            animatedCoverArt
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
                LucideIcon(isPlaying ? .circlePause : .circlePlay, size: 64, color: Color.appPrimaryText)
            }
            .disabled(!tile.isAvailable)

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(backgroundLayer)
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

    // Layers the BlobShape deformation on top of the existing scale/opacity
    // pulse. The per-frame TimelineView only runs while actually playing —
    // at rest this renders a plain, static BlobShape(amplitude: 0), which is
    // exactly a circle, with no continuous timer burning CPU in the
    // background. Foreground cover art only; backgroundLayer below keeps
    // its own plain shape unchanged.
    @ViewBuilder
    private var animatedCoverArt: some View {
        if isPlaying {
            TimelineView(.animation) { timeline in
                blobClippedCoverArt(phase: phase(at: timeline.date))
            }
        } else {
            blobClippedCoverArt(phase: 0)
        }
    }

    private func blobClippedCoverArt(phase: CGFloat) -> some View {
        coverArt
            .frame(width: 180, height: 180)
            .clipShape(BlobShape(amplitude: isPlaying ? viewModel.previewLevel : 0, phase: phase))
            .scaleEffect(isPlaying ? 1 + viewModel.previewLevel * 0.12 : 1)
            .opacity(isPlaying ? 0.85 + viewModel.previewLevel * 0.15 : 1)
            .animation(.easeInOut(duration: 0.12), value: viewModel.previewLevel)
    }

    // Radians/sec — slow, organic drift rather than a visible spin.
    private let blobRotationSpeed: Double = 1.4

    private func phase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate * blobRotationSpeed)
    }

    /// The sheet's own cover art, blown up to fill the background at low
    /// opacity (blurred + scrimmed so the foreground text/controls stay
    /// legible over any cover) — the same ambient-art treatment Music/
    /// Podcasts-style players use behind their now-playing screen.
    private var backgroundLayer: some View {
        ZStack {
            Color.appBackground
            coverArt
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 30)
                .opacity(0.4)
            Color.appBackground.opacity(0.55)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    VoicePreviewSheet(
        tile: VoiceTile(
            id: "kokoro-af_heart", name: "af_heart", engine: .kokoroAne, engineLabel: "Kokoro-ANE",
            isAvailable: true),
        viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
