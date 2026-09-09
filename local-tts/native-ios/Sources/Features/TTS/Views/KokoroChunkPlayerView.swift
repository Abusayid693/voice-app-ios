import SwiftUI

/// Audio-player-style control for Kokoro-ANE's chunked playback: a
/// play/pause/buffering button plus a segmented bar — one segment per
/// chunk, colored by state (playing / already generated / still waiting on
/// generation) — so long text visibly plays as soon as the first chunk is
/// ready instead of waiting for the whole thing.
struct KokoroChunkPlayerView: View {
    @ObservedObject var viewModel: TTSViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: viewModel.toggleKokoroPlayback) {
                    if viewModel.isKokoroBuffering {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: viewModel.isKokoroPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isKokoroBuffering || viewModel.kokoroChunkStates.isEmpty)

                if !viewModel.kokoroChunkStates.isEmpty {
                    Text("Chunk \(viewModel.kokoroChunkIndex + 1) of \(viewModel.kokoroChunkStates.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if !viewModel.kokoroChunkStates.isEmpty {
                HStack(spacing: 3) {
                    ForEach(viewModel.kokoroChunkStates.indices, id: \.self) { index in
                        Capsule()
                            .fill(color(for: viewModel.kokoroChunkStates[index]))
                            .frame(height: 4)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for state: ChunkState) -> Color {
        switch state {
        case .playing: return .blue
        case .generated: return Color.blue.opacity(0.3)
        case .waiting: return Color.gray.opacity(0.25)
        }
    }
}
