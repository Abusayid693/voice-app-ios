import LucideSwift
import SwiftUI

/// Full-screen text entry reached from Import's "Write text" card. Generate
/// no longer synthesizes anything here — it only saves the text, split into
/// chapters (`LibraryViewModel.save`), and hands the new project's id up via
/// `onGenerated` so the caller can push `ChaptersListView`. Per-chapter
/// audio (streamed or, for Kokoro, generated-and-saved) happens there.
struct WriteTextView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var packs: VoicePackStore
    let onGenerated: (UUID) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $viewModel.text)
                    .appText(.reading)
                    .scrollContentBackground(.hidden)
                    .background(Color.appBackground)
                    .padding(4)

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
                // the leading side is otherwise empty.
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
        }
        // Warm the model now rather than on a later per-chapter Generate —
        // opening this screen is a clear signal the user is about to write,
        // so the load usually finishes while they're still typing.
        .task { viewModel.prepareKokoroModelIfNeeded() }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isVoiceSettingsPresented) {
            VoiceSettingsSheet(
                viewModel: viewModel, packs: packs, voiceCloneViewModel: voiceCloneViewModel)
        }
    }

    // The currently selected voice, whichever engine it belongs to — same
    // resolution `generate()` already uses for Pocket's cloned-vs-named
    // voice, so the avatar always matches what Generate will actually use.
    private var currentVoiceAssetName: String {
        switch viewModel.engine {
        case .kokoroAne: return VoiceCoverArt.assetName(for: viewModel.kokoroVoice)
        case .pocketTts:
            return VoiceCoverArt.assetName(for: viewModel.selectedClonedVoice?.name ?? viewModel.pocketVoice)
        case .supertonic3: return VoiceCoverArt.assetName(for: viewModel.supertonicVoice.rawValue)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.isVoiceSettingsPresented = true
            } label: {
                Image(currentVoiceAssetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            }

            Button(action: generate) {
                Text("Generate")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .disabled(viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(height: 44)
        }
        .padding()
    }

    // Saves the text (split into chapters) and hands the new project's id
    // to the caller — no audio is synthesized here anymore (see this
    // file's doc comment).
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
        guard
            let savedID = libraryViewModel.save(
                text: viewModel.text, engine: viewModel.engine, voiceName: voiceName)
        else { return }
        onGenerated(savedID)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    WriteTextView(
        viewModel: viewModel,
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel(), packs: viewModel.packs, onGenerated: { _ in })
}
