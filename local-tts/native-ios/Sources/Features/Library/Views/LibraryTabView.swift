import SwiftUI

/// The Library tab: every past "Generate" tap's original text + voice
/// used. Swipe a row for Delete or the pen icon (view the original text,
/// read-only). Playback isn't wired up yet — see issue #11 — this is
/// metadata/text only for now.
struct LibraryTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var viewingGeneration: SavedGeneration?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.savedGenerations.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.savedGenerations) { generation in
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
                Text("\(generation.voiceName) · \(generation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { viewingGeneration = generation }
    }
}

#Preview {
    LibraryTabView(viewModel: LibraryViewModel())
}
