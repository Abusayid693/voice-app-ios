import LucideSwift
import SwiftUI

/// Read-along screen for a Kokoro generation (issue #10), reached by
/// navigating from WriteTextView's Generate button — deliberately its own
/// screen with a plain, read-only scrolling text view, not an overlay
/// inside WriteTextView's editable `TextEditor` (highlighted ranges and an
/// editable text view fight each other: cursor placement, selection,
/// live-typing all get in the way of programmatically-driven highlight
/// state). See ENG_CONTEXT.md's "Read-along player" section.
///
/// Highlights a whole chunk at a time (word-level was tried and reverted —
/// Kokoro's own text normalizer expands numbers/dates/times before
/// phonemizing, e.g. "26" -> "twenty six", which broke the word-count
/// alignment for any chunk containing them; common enough in real pasted
/// text that chunk-level is the more reliable v1 — see ENG_CONTEXT.md).
///
/// Looks the live generation up by id on every render (rather than holding
/// a value-type snapshot) so it reflects chunk audio/playback state as they
/// keep changing while this screen is open.
struct ReadAlongPlayerView: View {
    let generationID: KokoroGeneration.ID
    @ObservedObject var viewModel: TTSViewModel

    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    private var generation: KokoroGeneration? {
        viewModel.kokoroGenerations.first { $0.id == generationID }
    }

    var body: some View {
        Group {
            if let generation {
                content(for: generation)
            } else {
                Color.appBackground.ignoresSafeArea()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(for generation: KokoroGeneration) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(generation.chunkTexts.indices, id: \.self) { index in
                        chunkText(generation: generation, index: index)
                            .id(index)
                    }
                }
                .padding()
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    isUserScrolling = true
                    scrollResumeTask?.cancel()
                    scrollResumeTask = Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        isUserScrolling = false
                    }
                }
            )
            .onChange(of: generation.currentChunkIndex) { _, chunkIndex in
                guard !isUserScrolling else { return }
                withAnimation { proxy.scrollTo(chunkIndex, anchor: .center) }
            }
            .overlay(alignment: .top) {
                if isUserScrolling {
                    Button("Jump to current") {
                        scrollResumeTask?.cancel()
                        isUserScrolling = false
                        withAnimation { proxy.scrollTo(generation.currentChunkIndex, anchor: .center) }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                }
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { playerBar(generation: generation) }
    }

    private func chunkText(generation: KokoroGeneration, index: Int) -> some View {
        let isCurrentChunk = index == generation.currentChunkIndex && generation.isPlaying
        return Text(generation.chunkTexts[index])
            .font(.title3)
            .foregroundStyle(isCurrentChunk ? Color.appPrimaryText : Color.appSecondaryText)
            // Without this, the Text only sizes to its own glyph width
            // inside the leading-aligned VStack, so the highlight rectangle
            // below hugs the words instead of spanning the full row.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(
                isCurrentChunk ? Color.appSecondaryBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 8))
    }

    private func playerBar(generation: KokoroGeneration) -> some View {
        VStack(spacing: 12) {
            Button {
                viewModel.toggleKokoroPlayback(for: generation.id)
            } label: {
                // Same buffering-vs-play/pause treatment as
                // KokoroGenerationListView's row — covers the initial chunk
                // not being ready yet (right after navigating here from
                // Generate) as well as any later chunk needing to catch up.
                if generation.isBuffering {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    LucideIcon(
                        generation.isPlaying ? .circlePause : .circlePlay, size: 32,
                        color: Color.appPrimaryText)
                }
            }
            .disabled(generation.isBuffering)

            // Same per-chunk segmented bar as KokoroGenerationListView,
            // instead of one continuous progress bar.
            HStack(spacing: 3) {
                ForEach(generation.chunkStates.indices, id: \.self) { index in
                    Capsule()
                        .fill(generation.chunkStates[index].displayColor)
                        .frame(height: 4)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
        .padding()
    }
}

#Preview {
    let dependencies = DependencyContainer()
    NavigationStack {
        ReadAlongPlayerView(generationID: UUID(), viewModel: TTSViewModel(dependencies: dependencies))
    }
}
