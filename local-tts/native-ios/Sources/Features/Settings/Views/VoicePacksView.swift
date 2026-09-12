import LucideSwift
import SwiftUI

/// Settings > Voice Packs — real download/size status for both engines'
/// packs (see issue #9). Deletion isn't offered yet: Kokoro's pack is
/// bundled with the app (nothing to re-download if removed), and Pocket has
/// no re-download-on-demand path from here yet — both are flagged as
/// follow-ups in docs/adr/0007-bundled-vs-downloaded-pack-asymmetry.md.
struct VoicePacksView: View {
    @ObservedObject var viewModel: TTSViewModel

    private var kokoroSizeBytes: Int64 {
        guard let directory = viewModel.kokoroModelDirectory else { return 0 }
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
                    isReady: viewModel.isKokoroPackReady,
                    sizeBytes: viewModel.isKokoroPackReady ? kokoroSizeBytes : nil)
                packRow(
                    title: "Pocket TTS",
                    subtitle: "\(TTSViewModel.pocketVoices.count) English voices",
                    isReady: viewModel.isPocketPackDownloaded,
                    sizeBytes: viewModel.isPocketPackDownloaded ? pocketSizeBytes : nil)
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
                Text(title).foregroundStyle(Color.appPrimaryText)
                Text(subtitle).font(.caption).foregroundStyle(Color.appSecondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    title: { Text(isReady ? "Downloaded" : "Not downloaded") },
                    icon: { LucideIcon(isReady ? .circleCheck : .circleArrowDown) }
                )
                .font(.caption)
                .foregroundStyle(isReady ? Color.appPrimaryText : Color.appSecondaryText)
                if let sizeBytes {
                    Text(DiskStorage.formattedSize(sizeBytes))
                        .font(.caption2)
                        .foregroundStyle(Color.appTertiaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        VoicePacksView(viewModel: TTSViewModel(dependencies: DependencyContainer()))
    }
}
