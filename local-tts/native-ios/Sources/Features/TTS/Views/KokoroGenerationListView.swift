import LucideSwift
import SwiftUI

/// One row per "Generate" tap — independent tracks, like a playlist, each
/// with its own play/pause/buffering button. Long text still splits into
/// sub-chunks internally (Kokoro's 510-phoneme cap) — each row's segmented
/// bar shows that sub-progress, but the row still plays back as one
/// continuous track with a single play button.
struct KokoroGenerationListView: View {
    @ObservedObject var viewModel: TTSViewModel

    var body: some View {
        if viewModel.kokoroGenerations.isEmpty {
            Text("Tap Generate to create a track.")
                .appText(.label)
        } else {
            ForEach(viewModel.kokoroGenerations) { generation in
                KokoroGenerationRow(
                    generation: generation,
                    onToggle: { viewModel.toggleKokoroPlayback(for: generation.id) }
                )
            }
        }
    }
}

private struct KokoroGenerationRow: View {
    let generation: KokoroGeneration
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    if generation.isBuffering {
                        ProgressView()
                            .frame(width: 28, height: 28)
                    } else {
                        LucideIcon(generation.isPlaying ? .circlePause : .circlePlay, size: 28)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(generation.text)
                            .appText(.rowTitle)
                            .lineLimit(1)
                        if let error = generation.error {
                            Text("Error: \(error)")
                                .appText(.metaError)
                                .lineLimit(2)
                        } else if !generation.isFullyGenerated {
                            Text("Generating…")
                                .appText(.meta)
                        }
                    }

                    Spacer()
                }

                HStack(spacing: 3) {
                    ForEach(generation.chunkStates.indices, id: \.self) { index in
                        Capsule()
                            .fill(generation.chunkStates[index].displayColor)
                            .frame(height: 4)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
