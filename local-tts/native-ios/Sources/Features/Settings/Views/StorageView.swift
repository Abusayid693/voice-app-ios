import SwiftUI

/// Settings > Storage — a real on-disk breakdown (see issue #9): the Kokoro
/// packs and generated chapter audio (Features/Chapters), each computed from
/// the actual directories they're written to (DiskStorage.directorySize),
/// not an estimate.
struct StorageView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore

    private var kokoroBytes: Int64 {
        guard packs.isKokoroPackReady(.english), let directory = packs.kokoroModelDirectory else {
            return 0
        }
        return DiskStorage.directorySize(at: directory)
    }

    // 0 (not shown as "unknown") while the exact directory hasn't been
    // resolved yet this session — see kokoroMandarinModelDirectory's doc
    // comment. Total below still undercounts in that window.
    private var kokoroMandarinBytes: Int64 {
        guard packs.isKokoroPackReady(.mandarin), let directory = packs.kokoroMandarinModelDirectory
        else { return 0 }
        return DiskStorage.directorySize(at: directory)
    }

    // Generated chapter audio (Features/Chapters) — merged WAVs saved
    // under SavedGenerations/<project id>/, one per generated chapter.
    // Absent from this breakdown until now (see docs/adr/0010's
    // "Consequences" — flagged as a known gap when chapters shipped).
    private var savedGenerationsBytes: Int64 {
        DiskStorage.directorySize(at: SavedGeneration.baseDirectory)
    }

    private var totalBytes: Int64 {
        kokoroBytes + kokoroMandarinBytes + savedGenerationsBytes
    }

    var body: some View {
        List {
            Section {
                row(title: "Kokoro-ANE pack", bytes: kokoroBytes)
                row(title: "Kokoro-ANE pack (Mandarin)", bytes: kokoroMandarinBytes)
                row(title: "Generated chapters", bytes: savedGenerationsBytes)
            }
            .listRowBackground(Color.appSecondaryBackground)

            Section {
                HStack {
                    Text("Total").appText(.rowTitle)
                    Spacer()
                    Text(DiskStorage.formattedSize(totalBytes))
                        .appText(.bodyStrong)
                }
            }
            .listRowBackground(Color.appSecondaryBackground)
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: String, bytes: Int64) -> some View {
        HStack {
            Text(title).appText(.rowTitle)
            Spacer()
            Text(DiskStorage.formattedSize(bytes)).appText(.body)
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    NavigationStack {
        StorageView(viewModel: viewModel, packs: viewModel.packs)
    }
}
