import SwiftUI

/// The Voices tab: manage cloned voices — create new ones, preview or
/// delete existing ones. Selecting one for actual generation happens from
/// VoiceSettingsSheet's "My Voices" section, not here.
struct VoicesTabView: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    @State private var isRecordingPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.clonedVoices.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.clonedVoices) { voice in
                            row(for: voice)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                viewModel.deleteVoice(viewModel.clonedVoices[index])
                            }
                        }
                        .listRowBackground(Color.appSecondaryBackground)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Voices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isRecordingPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $isRecordingPresented) {
            RecordVoiceView(viewModel: viewModel)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.appSecondaryText)
            Text("No cloned voices yet")
                .foregroundStyle(Color.appSecondaryText)
            Button("Create your own voice") { isRecordingPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for voice: ClonedVoice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2.fill")
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .foregroundStyle(Color.appPrimaryText)
                Text(voice.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }

            Spacer()

            Button {
                viewModel.togglePreview(for: voice)
            } label: {
                if viewModel.previewingVoiceID == voice.id && viewModel.isPreviewLoading {
                    ProgressView()
                } else {
                    Image(
                        systemName: viewModel.previewingVoiceID == voice.id
                            ? "pause.circle.fill" : "play.circle.fill"
                    )
                    .font(.title2)
                    .foregroundStyle(Color.appPrimaryText)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    VoicesTabView(viewModel: VoiceCloneViewModel(dependencies: DependencyContainer()))
}
