import SwiftUI

/// Full-screen text entry reached from Import's "Write text" card. Floating
/// Generate + Settings buttons at the bottom. Kokoro's Generate navigates
/// straight to ReadAlongPlayerView (issue #10) — no inline player here
/// anymore. Pocket TTS still shows its progress inline (pocketStatusCard),
/// unchanged.
struct WriteTextView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    // Set the moment a Kokoro Generate tap creates a new track — pushes
    // ReadAlongPlayerView immediately (chunks stream in progressively there,
    // same as today's inline list did). Pocket TTS doesn't use this; its
    // Generate keeps today's inline pocketStatusCard, no navigation.
    @State private var readAlongGenerationID: KokoroGeneration.ID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $viewModel.text)
                    .font(.title3)
                    .foregroundStyle(Color.appPrimaryText)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { viewModel.isWriteTextPresented = false }) {
                        Image(systemName: "xmark")
                            .foregroundStyle(Color.appPrimaryText)
                    }
                }
            }
            .navigationDestination(item: $readAlongGenerationID) { generationID in
                ReadAlongPlayerView(generationID: generationID, viewModel: viewModel)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isVoiceSettingsPresented) {
            VoiceSettingsSheet(viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel)
        }
    }

    // Kokoro no longer shows its own inline player here — Generate
    // navigates straight to ReadAlongPlayerView, which is now the only
    // place Kokoro generations are played back from. Pocket is unchanged.
    @ViewBuilder
    private var progressArea: some View {
        if viewModel.engine == .pocketTts, viewModel.isBusy || viewModel.timeToFirstAudio != nil {
            pocketStatusCard
        }
    }

    private var pocketStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Status") {
                Text(viewModel.status).foregroundStyle(Color.appSecondaryText)
            }
            .foregroundStyle(Color.appPrimaryText)
            if viewModel.isBusy, viewModel.initSeconds == nil {
                ProgressView(value: viewModel.downloadFraction)
            }
            if let streamChunkProgress = viewModel.streamChunkProgress {
                LabeledContent("Chunk") {
                    Text(streamChunkProgress).foregroundStyle(Color.appSecondaryText)
                }
                .foregroundStyle(Color.appPrimaryText)
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
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.appSecondaryBackground))
            }

            Button(action: generate) {
                if viewModel.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Generate")
                        .bold()
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
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
    // Pocket keeps today's behavior unchanged (inline pocketStatusCard, no
    // saved audio — see SavedGeneration's doc comment).
    private func generate() {
        let voiceName: String
        switch viewModel.engine {
        case .kokoroAne:
            voiceName = viewModel.kokoroVoice
        case .pocketTts:
            voiceName = viewModel.selectedClonedVoice?.name ?? viewModel.pocketVoice
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
        case .pocketTts:
            viewModel.runDownloadAndSpeak()
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    WriteTextView(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel())
}
