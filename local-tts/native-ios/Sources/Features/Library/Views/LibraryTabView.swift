import LucideSwift
import SwiftUI

/// The Library tab: every past "Generate" tap's original text + voice
/// used. Tapping a Kokoro row opens the same ReadAlongPlayerView a live
/// Generate uses, playing the persisted per-chunk audio where it exists and
/// regenerating live where it doesn't — see LibraryPlayback, which owns that
/// fallback. Pocket rows still just open the read-only text view, since
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
                                        Label(title: { Text("Delete") }, icon: { LucideIcon(.trash) })
                                    }
                                    Button {
                                        viewingGeneration = generation
                                    } label: {
                                        Label(title: { Text("View Text") }, icon: { LucideIcon(.pencil) })
                                    }
                                    .tint(.blue)
                                }
                        }
                        .listRowBackground(Color.appSecondaryBackground)
                    }
                    // Matches ImportHomeView's own gap under its nav
                    // title (.padding(.top, 8) on its content) — List
                    // has no equivalent top inset by default.
                    .contentMargins(.top, 8, for: .scrollContent)
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
                        LucideIcon(sortNewestFirst ? .arrowDown : .arrowUp)
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
            LucideIcon(.library, size: 48, color: Color.appSecondaryText)
            Text("No generations yet")
                .appText(.body)
            Text("Text you generate from Write Text will show up here.")
                .appText(.labelDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for generation: SavedGeneration) -> some View {
        GenerationRow(
            icon: generation.engine == .kokoroAne ? .audioWaveform : .mic,
            iconStyle: generation.engine == .kokoroAne ? .stroked : .filled,
            title: generation.text,
            subtitle:
                "\(VoiceDisplayName.forCode(generation.voiceName)) · \(generation.createdAt.formatted(date: .abbreviated, time: .shortened))",
            onTap: { open(generation) }
        )
    }

    private func open(_ generation: SavedGeneration) {
        switch generation.engine {
        case .kokoroAne:
            if let newID = LibraryPlayback.open(
                generation, ttsViewModel: ttsViewModel, libraryViewModel: viewModel)
            {
                readAlongGenerationID = newID
            }
        case .pocketTts, .supertonic3:
            // Neither has a player screen or saved audio yet (see
            // SavedGeneration's doc comment) — keep the existing read-only
            // text view as the tap action for both.
            viewingGeneration = generation
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    LibraryTabView(viewModel: LibraryViewModel(), ttsViewModel: TTSViewModel(dependencies: dependencies))
}
