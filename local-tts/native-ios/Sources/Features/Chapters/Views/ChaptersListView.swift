import SwiftUI

/// Lists a saved project's chapters (issue: split Generate into
/// save-then-chapters). Every engine's chapters get a Play button
/// (streaming — synthesize and play, nothing saved, stays on this list);
/// Kokoro chapters additionally get a Generate button that synthesizes and
/// saves one merged WAV, after which Play opens `ChapterPlayerView`
/// instead of streaming inline.
///
/// Owns the coordination between the two playback mechanisms reachable
/// from here — `chapterPlayer` (Kokoro chapter audio, streamed or saved)
/// and `viewModel`'s own engine playback (Pocket/Supertonic streaming) —
/// since this is the one place both are in scope. Neither mechanism knows
/// about the other.
struct ChaptersListView: View {
    let project: SavedGeneration
    @ObservedObject var chapterPlayer: ChapterAudioPlayer
    @ObservedObject var generationStore: ChapterGenerationStore
    @ObservedObject var viewModel: TTSViewModel

    @State private var playerChapterRef: ChapterRef?
    // Pocket/Supertonic have no chunk-level player of their own to read
    // state from (see ChapterAudioPlayer's doc comment) — this is purely
    // "which row did the user last tap Play on", paired with
    // viewModel.isBusy to approximate a playing/idle state honestly rather
    // than inventing a real transport those engines don't have.
    @State private var nonKokoroActiveChapterIndex: Int?

    var body: some View {
        Group {
            if project.chapters.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(project.chapters) { chapter in
                        row(for: chapter)
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                }
                .contentMargins(.top, 8, for: .scrollContent)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Chapters")
        .navigationBarTitleDisplayMode(.inline)
        // Root tab bar is only for Home/Library/Tools/Voices themselves —
        // hidden on every pushed screen. RootTabView's own floating "+"
        // isn't part of the real tab bar, so it needs NavigationChromeVisibility
        // instead (set by the tab root that pushed this, not here).
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $playerChapterRef) { ref in
            ChapterPlayerView(project: project, chapterRef: ref, chapterPlayer: chapterPlayer)
        }
        // A streaming chapter is voice-scoped — changing voice mid-stream
        // would otherwise keep playing under a voice the user just left.
        .onChange(of: viewModel.kokoroVoice) { _, _ in chapterPlayer.stop() }
        .onChange(of: viewModel.kokoroVariant) { _, _ in chapterPlayer.stop() }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No chapters").appText(.body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for chapter: Chapter) -> some View {
        let ref = ChapterRef(projectID: project.id, chapterIndex: chapter.index)
        let isKokoro = project.engine == .kokoroAne
        let isGenerated = isKokoro && ChapterAudioStore.isGenerated(ref, project: project)
        let isActive = isKokoro ? chapterPlayer.isActive(ref) : nonKokoroActiveChapterIndex == chapter.index
        let isPlaying = isKokoro ? (isActive && chapterPlayer.isPlaying) : (isActive && viewModel.isBusy)
        let isBuffering = isKokoro && isActive && chapterPlayer.isBuffering

        return ChapterRow(
            chapter: chapter, voiceName: project.voiceName, isKokoro: isKokoro, isGenerated: isGenerated,
            isActive: isActive, isPlaying: isPlaying, isBuffering: isBuffering,
            generationState: generationStore.state(for: ref),
            onPlayTapped: { play(chapter: chapter, ref: ref, isGenerated: isGenerated) },
            onGenerateTapped: {
                generationStore.generate(
                    ref: ref, project: project, chapter: chapter, voice: project.voiceName)
            },
            onCancelGenerate: { generationStore.cancel(ref) })
    }

    private func play(chapter: Chapter, ref: ChapterRef, isGenerated: Bool) {
        if isGenerated {
            if chapterPlayer.isActive(ref) {
                chapterPlayer.togglePlayPause()
            } else {
                viewModel.stopEnginePlayback()
                chapterPlayer.playSaved(ref, project: project)
            }
            playerChapterRef = ref
            return
        }

        switch project.engine {
        case .kokoroAne:
            if chapterPlayer.isActive(ref) {
                chapterPlayer.togglePlayPause()
            } else {
                viewModel.stopEnginePlayback()
                chapterPlayer.stream(ref, chapter: chapter, voice: project.voiceName)
            }
        case .pocketTts, .supertonic3:
            chapterPlayer.stop()
            nonKokoroActiveChapterIndex = chapter.index
            viewModel.speakChapter(text: chapter.text)
        }
    }
}
