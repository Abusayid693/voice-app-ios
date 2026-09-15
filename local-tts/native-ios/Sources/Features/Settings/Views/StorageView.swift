import SwiftUI

/// Settings > Storage — a real on-disk breakdown (see issue #9): both voice
/// packs plus the user's own cloned voices, each computed from the actual
/// directories they're written to (DiskStorage.directorySize), not an
/// estimate.
struct StorageView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var packs: VoicePackStore

    private var kokoroBytes: Int64 {
        guard packs.isKokoroPackReady(.english), let directory = packs.kokoroModelDirectory else {
            return 0
        }
        return DiskStorage.directorySize(at: directory)
    }

    // 0 (not shown as "unknown") while the exact directory hasn't been
    // resolved yet this session — see kokoroMandarinModelDirectory's doc
    // comment. Total below still undercounts in that window, same known
    // imprecision as Pocket's own whole-cache-dir measurement.
    private var kokoroMandarinBytes: Int64 {
        guard packs.isKokoroPackReady(.mandarin), let directory = packs.kokoroMandarinModelDirectory
        else { return 0 }
        return DiskStorage.directorySize(at: directory)
    }

    private var pocketBytes: Int64 {
        guard packs.isPocketPackDownloaded else { return 0 }
        return DiskStorage.directorySize(at: DiskStorage.fluidAudioCacheDirectory)
    }

    // Same "0 until resolved this session" reasoning as kokoroMandarinBytes
    // — tracked as its own directory (not folded into pocketBytes' whole-
    // cache measurement) so this row doesn't double-count against Pocket's.
    private var supertonic3Bytes: Int64 {
        guard packs.isSupertonic3Downloaded, let directory = packs.supertonic3ModelDirectory else { return 0 }
        return DiskStorage.directorySize(at: directory)
    }

    private var clonedVoicesBytes: Int64 {
        DiskStorage.directorySize(at: ClonedVoice.directory)
    }

    private var totalBytes: Int64 {
        kokoroBytes + kokoroMandarinBytes + pocketBytes + supertonic3Bytes + clonedVoicesBytes
    }

    var body: some View {
        List {
            Section {
                row(title: "Kokoro-ANE pack", bytes: kokoroBytes)
                row(title: "Kokoro-ANE pack (Mandarin)", bytes: kokoroMandarinBytes)
                row(title: "Pocket TTS pack", bytes: pocketBytes)
                row(title: "Supertonic-3 pack", bytes: supertonic3Bytes)
                row(
                    title: "My voices (\(voiceCloneViewModel.clonedVoices.count))",
                    bytes: clonedVoicesBytes)
            }
            .listRowBackground(Color.appSecondaryBackground)

            Section {
                HStack {
                    Text("Total").font(.appRowTitle).foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    Text(DiskStorage.formattedSize(totalBytes))
                        .font(.appBody)
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
            Text(title).font(.appRowTitle).foregroundStyle(Color.appPrimaryText)
            Spacer()
            Text(DiskStorage.formattedSize(bytes)).font(.appBody).foregroundStyle(Color.appSecondaryText)
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    NavigationStack {
        StorageView(
            viewModel: viewModel,
            voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
            packs: viewModel.packs)
    }
}
