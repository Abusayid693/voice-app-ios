import SwiftUI

/// Full-screen text entry reached from Import's "Write text" card. Floating
/// Generate + Settings buttons at the bottom; generation progress/playback
/// shows inline below the editor rather than navigating away.
struct WriteTextView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel

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
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isVoiceSettingsPresented) {
            VoiceSettingsSheet(viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel)
        }
    }

    @ViewBuilder
    private var progressArea: some View {
        switch viewModel.engine {
        case .kokoroAne:
            if !viewModel.kokoroGenerations.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        KokoroGenerationListView(viewModel: viewModel)
                    }
                }
                .frame(maxHeight: 220)
            }
        case .pocketTts:
            if viewModel.isBusy || viewModel.timeToFirstAudio != nil {
                pocketStatusCard
            }
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

            Button(action: viewModel.runDownloadAndSpeak) {
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
}

#Preview {
    let dependencies = DependencyContainer()
    WriteTextView(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies))
}
