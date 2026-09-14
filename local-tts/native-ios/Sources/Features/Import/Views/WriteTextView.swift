import LucideSwift
import SwiftUI

/// Full-screen text entry reached from Import's "Write text" card. Floating
/// Generate + Settings buttons at the bottom. Kokoro's Generate navigates
/// straight to ReadAlongPlayerView (issue #10) — no inline player here
/// anymore. Pocket TTS, Supertonic-3, and Chatterbox Nano all still show
/// progress inline (`statusCard`), unchanged.
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

    // Chatterbox Nano's real cap is on *generated audio duration*
    // (~10s — ChatterboxNanoConstants.flowTokenBucket minus the bundled
    // voice's fixed 250-token prompt, see docs/adr/0010), not on input
    // text directly, so there's no exact character limit to enforce —
    // spoken pacing, punctuation, and tags like [chuckle] all affect the
    // real token count in ways this app can't predict without running the
    // model. This is a conservative estimate (confirmed empirically: a
    // ~148-char clip generated fine, ~156 chars did not) meant to catch
    // clearly-too-long text before a guaranteed-wasted attempt — the SDK's
    // own `ChatterboxError.generationTooLong` is still the real backstop
    // for text that slips under this and still runs long.
    private static let chatterboxNanoSoftCharLimit = 140

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $viewModel.text)
                    .font(.title3)
                    .foregroundStyle(Color.appPrimaryText)
                    .scrollContentBackground(.hidden)
                    .background(Color.appBackground)
                    .padding(4)

                chatterboxNanoTagHint
                    .padding(.horizontal)

                progressArea
                    .padding(.horizontal)

                bottomBar
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isVoiceSettingsPresented) {
            VoiceSettingsSheet(
                viewModel: viewModel, packs: packs, voiceCloneViewModel: voiceCloneViewModel)
        }
    }

    private var isChatterboxNanoTextTooLong: Bool {
        viewModel.engine == .chatterboxNano
            && viewModel.text.count > Self.chatterboxNanoSoftCharLimit
    }

    // No tag-insertion UI (see docs/adr/0010) — just naming a few examples
    // so they're discoverable without reading external docs. The character
    // count doubles as the length warning — see chatterboxNanoSoftCharLimit.
    @ViewBuilder
    private var chatterboxNanoTagHint: some View {
        if viewModel.engine == .chatterboxNano {
            HStack {
                Text("Try [laugh], [sigh], [whispering] inline in your text.")
                    .font(.caption)
                    .foregroundStyle(Color.appTertiaryText)
                Spacer()
                Text("\(viewModel.text.count)/\(Self.chatterboxNanoSoftCharLimit)")
                    .font(.caption)
                    .foregroundStyle(isChatterboxNanoTextTooLong ? .red : Color.appTertiaryText)
            }
        }
    }

    // Kokoro no longer shows its own inline player here — Generate
    // navigates straight to ReadAlongPlayerView, which is now the only
    // place Kokoro generations are played back from. Pocket, Supertonic-3,
    // and Chatterbox Nano share this same inline card — none has a
    // dedicated playback screen (see SavedGeneration's doc comment).
    @ViewBuilder
    private var progressArea: some View {
        // `status != "Idle"` catches a failed run for Supertonic-3/Chatterbox
        // Nano: both set `status` to an error message and `isBusy = false`
        // together, with no lingering flag like Pocket's `timeToFirstAudio`
        // to keep the card up — without this, a run that fails before ever
        // starting playback flips isBusy false and the error disappears on
        // the very next render, never actually seen. Every success path
        // resets `status` back to "Idle" (its declared initial value), so
        // this only stays true while an unread error is sitting in it.
        if viewModel.engine != .kokoroAne,
            viewModel.isBusy || viewModel.timeToFirstAudio != nil || viewModel.status != "Idle"
        {
            statusCard
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Status") {
                Text(viewModel.status).foregroundStyle(Color.appSecondaryText)
            }
            .foregroundStyle(Color.appPrimaryText)
            if viewModel.isBusy, viewModel.initSeconds == nil {
                ProgressView(value: packs.fraction)
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
                LucideIcon(.cog, size: 20, color: Color.appPrimaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.appSecondaryBackground))
            }

            Button(action: generate) {
                if viewModel.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(isChatterboxNanoTextTooLong ? "Text too long" : "Generate")
                        .bold()
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy || viewModel.text.isEmpty || isChatterboxNanoTextTooLong)
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
        case .chatterboxNano:
            voiceName = "Expressive"
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
        case .pocketTts, .supertonic3, .chatterboxNano:
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
