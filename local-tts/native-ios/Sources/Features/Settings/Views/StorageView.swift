import SwiftUI

/// Settings > Storage — a real on-disk breakdown (see issue #9): both voice
/// packs plus the user's own cloned voices, each computed from the actual
/// directories they're written to (DiskStorage.directorySize), not an
/// estimate.
struct StorageView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel

    private var kokoroBytes: Int64 {
        guard viewModel.isKokoroPackReady(.english), let directory = viewModel.kokoroModelDirectory else {
            return 0
        }
        return DiskStorage.directorySize(at: directory)
    }

    // 0 (not shown as "unknown") while the exact directory hasn't been
    // resolved yet this session — see kokoroMandarinModelDirectory's doc
    // comment. Total below still undercounts in that window, same known
    // imprecision as Pocket's own whole-cache-dir measurement.
    private var kokoroMandarinBytes: Int64 {
        guard viewModel.isKokoroPackReady(.mandarin), let directory = viewModel.kokoroMandarinModelDirectory
        else { return 0 }
        return DiskStorage.directorySize(at: directory)
    }

    private var pocketBytes: Int64 {
        guard viewModel.isPocketPackDownloaded else { return 0 }
        return DiskStorage.directorySize(at: DiskStorage.fluidAudioCacheDirectory)
    }

    private var clonedVoicesBytes: Int64 {
        DiskStorage.directorySize(at: ClonedVoice.directory)
    }

    private var totalBytes: Int64 { kokoroBytes + kokoroMandarinBytes + pocketBytes + clonedVoicesBytes }

    var body: some View {
        List {
            Section {
                row(title: "Kokoro-ANE pack", bytes: kokoroBytes)
                row(title: "Kokoro-ANE pack (Mandarin)", bytes: kokoroMandarinBytes)
                row(title: "Pocket TTS pack", bytes: pocketBytes)
                row(
                    title: "My voices (\(voiceCloneViewModel.clonedVoices.count))",
                    bytes: clonedVoicesBytes)
            }
            .listRowBackground(Color.appSecondaryBackground)

            Section {
                HStack {
                    Text("Total").bold().foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    Text(DiskStorage.formattedSize(totalBytes))
                        .foregroundStyle(Color.appPrimaryText)
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
            Text(title).foregroundStyle(Color.appPrimaryText)
            Spacer()
            Text(DiskStorage.formattedSize(bytes)).foregroundStyle(Color.appSecondaryText)
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    NavigationStack {
        StorageView(
            viewModel: TTSViewModel(dependencies: dependencies),
            voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies))
    }
}
