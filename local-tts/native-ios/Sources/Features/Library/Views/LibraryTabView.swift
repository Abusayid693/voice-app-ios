import LucideSwift
import SwiftUI

/// The Library tab: every past "Generate" tap's original text, split into
/// chapters. Tapping a row (any engine) opens `ChaptersListView` for that
/// project. Swipe for Delete or the pen icon (view the original text,
/// read-only, regardless of engine).
struct LibraryTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    // Only handed onward to ChaptersListView (which observes them itself),
    // never read here — so they come from the non-observable container
    // rather than as parameters. See AppEnvironment.
    @Environment(\.app) private var app
    @State private var viewingGeneration: SavedGeneration?
    @State private var openProjectID: UUID?
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
            .navigationDestination(item: $openProjectID) { projectID in
                if let project = viewModel.savedGenerations.first(where: { $0.id == projectID }) {
                    ChaptersListView(
                        project: project, chapterPlayer: app.chapterPlayer,
                        generationStore: app.generationStore, viewModel: app.tts)
                }
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
        openProjectID = generation.id
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return LibraryTabView(viewModel: app.library)
        .environment(\.app, app)
}
