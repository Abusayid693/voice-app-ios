import SwiftUI

/// Settings > Storage — a real on-disk breakdown (see issue #9) of the Kokoro
/// packs, computed from the actual directories they're written to
/// (DiskStorage.directorySize), not an estimate. Reader audio is never
/// persisted (streamed and discarded per session), so there is nothing of
/// its own to break out here.
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

    private var totalBytes: Int64 {
        kokoroBytes + kokoroMandarinBytes
    }

    var body: some View {
        List {
            Section {
                row(title: "Kokoro-ANE pack", bytes: kokoroBytes)
                row(title: "Kokoro-ANE pack (Mandarin)", bytes: kokoroMandarinBytes)
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
