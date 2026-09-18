import LucideSwift
import SwiftUI

/// Full-screen text entry reached from Import's "Write text" card. Floating
/// Generate + Settings buttons at the bottom. Kokoro's Generate navigates
/// straight to ReadAlongPlayerView (issue #10) — no inline player here
/// anymore. Pocket TTS and Supertonic-3 still show progress inline
/// (`statusCard`), unchanged.
struct WriteTextView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var packs: VoicePackStore
    // Set the moment a Kokoro Generate tap creates a new track — pushes
    // ReadAlongPlayerView immediately (chunks stream in progressively there,
    // same as today's inline list did). Pocket TTS and Supertonic-3 don't
    // use this; their Generate keeps today's inline statusCard, no navigation.
    @State private var readAlongGenerationID: KokoroGeneration.ID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $viewModel.text)
                    .appText(.reading)
                    .scrollContentBackground(.hidden)
                    .background(Color.appBackground)
                    .padding(4)

                progressArea
                    .padding(.horizontal)

                bottomBar
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Leading, not trailing — .navigationBarTrailing packs
                // multiple items into one tight cluster, which squeezed
                // this two-line control into/behind the close button
                // instead of sitting cleanly beside it. This screen has no
                // title and no back button (it's a fullScreenCover), so
                // the leading side is otherwise empty. Kokoro's Generate
                // navigates to the read-along screen before the cold-start
                // load even finishes, so this simply isn't on screen during
                // that phase for Kokoro — only relevant while WriteTextView
                // itself is visible.
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.isPreparingModel {
                        ModelPreparingNotice(onDismiss: viewModel.dismissModelPreparingNotice)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { viewModel.isWriteTextPresented = false }) {
                        LucideIcon(.x, color: Color.appPrimaryText)
                    }
                }
            }
            .navigationDestination(item: $readAlongGenerationID) { generationID in
                ReadAlongPlayerView(generationID: generationID, viewModel: viewModel)
            }
        }
        // Warm the model now rather than on the Generate tap — opening this
        // screen is a clear signal the user is about to generate, so the
        // load usually finishes while they're still typing.
        .task { viewModel.prepareKokoroModelIfNeeded() }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isVoiceSettingsPresented) {
            VoiceSettingsSheet(
                viewModel: viewModel, packs: packs, voiceCloneViewModel: voiceCloneViewModel)
        }
    }

    // Kokoro no longer shows its own inline player here — Generate
    // navigates straight to ReadAlongPlayerView, which is now the only
    // place Kokoro generations are played back from. Pocket and
    // Supertonic-3 share this same inline card — neither has a dedicated
    // playback screen (see SavedGeneration's doc comment).
    @ViewBuilder
    private var progressArea: some View {
        if viewModel.engine != .kokoroAne, viewModel.isBusy || viewModel.timeToFirstAudio != nil {
            statusCard
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Status") {
                Text(viewModel.status).appText(.body)
            }
            .appText(.bodyStrong)
            if viewModel.isBusy, viewModel.initSeconds == nil {
                ProgressView(value: packs.fraction)
            }
            if let streamChunkProgress = viewModel.streamChunkProgress {
                LabeledContent("Chunk") {
                    Text(streamChunkProgress).appText(.body)
                }
                .appText(.bodyStrong)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.appSecondaryBackground))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.isVoiceSettingsPresented = true
            } label: {
                LucideIcon(.cog, size: 20, color: Color.appPrimaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.appSecondaryBackground))
            }

            Button(action: generate) {
                if viewModel.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Generate")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.primary)
            .disabled(viewModel.isBusy || viewModel.text.isEmpty)
            .frame(height: 44)
        }
        .padding()
    }

    // Saves the text/voice to Library before kicking off the real
    // generation — a saved entry is written on every tap for now (not
    // gated on success), matching how Kokoro's own track list already
    // works (a "Generate" tap always creates something, even if a chunk
    // later fails). Kokoro's audio is attached to that same saved entry
    // once every chunk finishes, so Library/Projects can replay it
    // straight from disk (see LibraryPlayback) instead of regenerating.
    // Kokoro navigates straight to the read-along screen (issue #10);
    // Pocket and Supertonic-3 keep today's behavior unchanged (inline
    // statusCard, no saved audio — see SavedGeneration's doc comment).
    private func generate() {
        let voiceName: String
        switch viewModel.engine {
        case .kokoroAne:
            voiceName = viewModel.kokoroVoice
        case .pocketTts:
            voiceName = viewModel.selectedClonedVoice?.name ?? viewModel.pocketVoice
        case .supertonic3:
            voiceName = viewModel.supertonicVoice.displayName
        }
        let savedID = libraryViewModel.save(text: viewModel.text, engine: viewModel.engine, voiceName: voiceName)

        switch viewModel.engine {
        case .kokoroAne:
            let newID = viewModel.generateKokoro(onFullyGenerated: { chunkAudio in
                guard let savedID else { return }
                libraryViewModel.attachAudio(chunkAudio, to: savedID)
            })
            if let newID {
                viewModel.toggleKokoroPlayback(for: newID)
                readAlongGenerationID = newID
            }
        case .pocketTts, .supertonic3:
            viewModel.runDownloadAndSpeak()
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    WriteTextView(
        viewModel: viewModel,
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel(), packs: viewModel.packs)
}
