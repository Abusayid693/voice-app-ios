import LucideSwift
import SwiftUI

/// Settings > Voice Packs — real download/size status for every engine's
/// packs (see issue #9). Deletion isn't offered yet: Kokoro's pack is
/// bundled with the app (nothing to re-download if removed), and Pocket
/// has no re-download-on-demand path from here yet — flagged as a follow-up
/// in docs/adr/0007-bundled-vs-downloaded-pack-asymmetry.md.
struct VoicePacksView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore

    private var kokoroSizeBytes: Int64 {
        guard let directory = packs.kokoroModelDirectory else { return 0 }
        return DiskStorage.directorySize(at: directory)
    }

    // nil (not 0) while the exact directory hasn't been resolved yet this
    // session — see kokoroMandarinModelDirectory's doc comment.
    private var kokoroMandarinSizeBytes: Int64? {
        guard let directory = packs.kokoroMandarinModelDirectory else { return nil }
        return DiskStorage.directorySize(at: directory)
    }

    private var pocketSizeBytes: Int64 {
        DiskStorage.directorySize(at: DiskStorage.fluidAudioCacheDirectory)
    }

    var body: some View {
        List {
            Section {
                packRow(
                    title: "Kokoro-ANE",
                    subtitle: "\(TTSViewModel.kokoroVoices.count) English voices",
                    isReady: packs.isKokoroPackReady(.english),
                    sizeBytes: packs.isKokoroPackReady(.english) ? kokoroSizeBytes : nil)
                packRow(
                    title: "Kokoro-ANE (Mandarin)",
                    subtitle: "\(TTSViewModel.mandarinVoices.count) Mandarin voices",
                    isReady: packs.isKokoroPackReady(.mandarin),
                    sizeBytes: packs.isKokoroPackReady(.mandarin) ? kokoroMandarinSizeBytes : nil)
                packRow(
                    title: "Pocket TTS",
                    subtitle: "\(TTSViewModel.pocketVoices.count) English voices",
                    isReady: packs.isPocketPackDownloaded,
                    sizeBytes: packs.isPocketPackDownloaded ? pocketSizeBytes : nil)
            }
            .listRowBackground(Color.appSecondaryBackground)
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Voice Packs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func packRow(title: String, subtitle: String, isReady: Bool, sizeBytes: Int64?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.rowTitle)
                Text(subtitle).appText(.label)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    title: { Text(isReady ? "Downloaded" : "Not downloaded") },
                    icon: { LucideIcon(isReady ? .circleCheck : .circleArrowDown) }
                )
                .appText(isReady ? .labelStrong : .label)
                if let sizeBytes {
                    Text(DiskStorage.formattedSize(sizeBytes))
                        .appText(.meta)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    NavigationStack {
        VoicePacksView(viewModel: viewModel, packs: viewModel.packs)
    }
}
