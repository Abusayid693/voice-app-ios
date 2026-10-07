import LucideSwift
import SwiftUI

/// Library tab root. Tapping a project delegates to the app-wide reader route
/// so the complete tab surface is replaced while reading.
struct LibraryTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onOpenProject: (SavedGeneration) -> Void
    @State private var sortNewestFirst = true

    private var sortedGenerations: [SavedGenerationSummary] {
        sortNewestFirst
            ? viewModel.savedGenerations.sorted { $0.createdAt > $1.createdAt }
            : viewModel.savedGenerations.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
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
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(.library, size: 48, color: Color.appSecondaryText)
            Text("No generations yet")
                .appText(.body)
            Text("Books you import will show up here.")
                .appText(.labelDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for generation: SavedGenerationSummary) -> some View {
        GenerationRow(
            icon: .audioWaveform,
            iconStyle: .stroked,
            coverURL: generation.coverURL,
            title: generation.title,
            subtitle:
                "\(generation.pageCountLabel) · \(VoiceDisplayName.forCode(generation.voiceName)) · \(generation.createdAt.formatted(date: .abbreviated, time: .shortened))",
            onTap: { open(generation) }
        )
    }

    private func open(_ generation: SavedGenerationSummary) {
        guard let project = viewModel.project(for: generation.id) else { return }
        onOpenProject(project)
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return NavigationStack {
        LibraryTabView(viewModel: app.library, onOpenProject: { _ in })
    }
    .preferredColorScheme(.dark)
}
