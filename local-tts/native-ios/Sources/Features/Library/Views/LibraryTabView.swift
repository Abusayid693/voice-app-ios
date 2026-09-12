import SwiftUI

/// The Library tab: every past "Generate" tap's original text + voice
/// used. Tapping a Kokoro row re-synthesizes it and opens the same
/// ReadAlongPlayerView a live Generate uses (no audio is persisted — see
/// SavedGeneration — so "opening" a saved entry means regenerating it
/// fresh). Pocket rows still just open the read-only text view, since
/// there's no Pocket player screen yet. Swipe for Delete or the pen icon
/// (view the original text, read-only, regardless of engine).
struct LibraryTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var ttsViewModel: TTSViewModel
    @State private var viewingGeneration: SavedGeneration?
    @State private var readAlongGenerationID: KokoroGeneration.ID?
    @State private var sortNewestFirst = true

    private var sortedGenerations: [SavedGeneration] {
        sortNewestFirst
            ? viewModel.savedGenerations.sorted { $0.createdAt > $1.createdAt }
            : viewModel.savedGenerations.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.savedGenerations.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sortedGenerations) { generation in
                            row(for: generation)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        viewModel.delete(generation)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        viewingGeneration = generation
                                    } label: {
                                        Label("View Text", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                        .listRowBackground(Color.appSecondaryBackground)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        sortNewestFirst.toggle()
                    } label: {
                        Image(systemName: sortNewestFirst ? "arrow.down" : "arrow.up")
                    }
                }
            }
            .navigationDestination(item: $readAlongGenerationID) { generationID in
                ReadAlongPlayerView(generationID: generationID, viewModel: ttsViewModel)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $viewingGeneration) { generation in
            GenerationTextSheet(generation: generation)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(Color.appSecondaryText)
            Text("No generations yet")
                .foregroundStyle(Color.appSecondaryText)
            Text("Text you generate from Write Text will show up here.")
                .font(.caption)
                .foregroundStyle(Color.appTertiaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for generation: SavedGeneration) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.appBackground)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: generation.engine == .kokoroAne ? "waveform" : "mic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.appPrimaryText)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(generation.text)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(2)
                Text(
                    "\(VoiceDisplayName.forCode(generation.voiceName)) · \(generation.createdAt.formatted(date: .abbreviated, time: .shortened))"
                )
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { open(generation) }
    }

    private func open(_ generation: SavedGeneration) {
        switch generation.engine {
        case .kokoroAne:
            if let newID = LibraryPlayback.open(
                generation, ttsViewModel: ttsViewModel, libraryViewModel: viewModel)
            {
                readAlongGenerationID = newID
            }
        case .pocketTts:
            // No Pocket player screen yet — keep the existing read-only
            // text view as the tap action for these.
            viewingGeneration = generation
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    LibraryTabView(viewModel: LibraryViewModel(), ttsViewModel: TTSViewModel(dependencies: dependencies))
}
