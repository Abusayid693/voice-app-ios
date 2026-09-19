import SwiftUI

/// Settings > Storage — a real on-disk breakdown (see issue #9): both voice
/// packs, the user's own cloned voices, and generated chapter audio
/// (Features/Chapters), each computed from the actual directories they're
/// written to (DiskStorage.directorySize), not an estimate.
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

    // Generated chapter audio (Features/Chapters) — merged WAVs saved
    // under SavedGenerations/<project id>/, one per generated chapter.
    // Absent from this breakdown until now (see docs/adr/0010's
    // "Consequences" — flagged as a known gap when chapters shipped).
    private var savedGenerationsBytes: Int64 {
        DiskStorage.directorySize(at: SavedGeneration.baseDirectory)
    }

    private var totalBytes: Int64 {
        kokoroBytes + kokoroMandarinBytes + pocketBytes + supertonic3Bytes + clonedVoicesBytes
            + savedGenerationsBytes
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
        StorageView(
            viewModel: viewModel,
            voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
            packs: viewModel.packs)
    }
}
