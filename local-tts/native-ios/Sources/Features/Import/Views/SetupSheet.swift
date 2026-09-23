import LucideSwift
import SwiftUI

/// Download controls presented from Settings. This remains a plain navigation
/// destination so the Settings stack owns its Back affordance and dismissal.
struct SetupView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore

    var body: some View {
        List {
            Section {
                ForEach(VoicePack.allCases) { pack in
                    packRow(for: pack)
                }
                .listRowBackground(Color.appSecondaryBackground)
            } footer: {
                Text("Download each voice pack to make its voices available when writing.")
                    .appText(.body)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Setup")
    }

    @ViewBuilder
    private func packRow(for pack: VoicePack) -> some View {
        let isReady = isReady(pack)
        // Precise per-row check — viewModel.isBusy alone is shared across
        // every pack (and generation), so with 6 rows now (Kokoro + 5
        // Pocket languages) gating the spinner on it made every
        // not-yet-downloaded row spin the instant any one started.
        let isDownloadingThis = packs.downloadingPackID == pack.id
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.title).appText(.rowTitle)
                    Text(pack.subtitle).appText(.label)
                }
                Spacer()
                if isReady {
                    LucideIcon(.circleCheck, color: .green)
                } else if isDownloadingThis {
                    ProgressView()
                } else {
                    Button("Download") { startDownload(pack) }
                        .buttonStyle(.secondary)
                        // Still disabled while a *different* pack downloads
                        // — the progress/status fields these downloads
                        // update are shared, not per-pack, so two at once
                        // would corrupt each other's display.
                        .disabled(viewModel.isBusy)
                }
            }
            if isDownloadingThis {
                ProgressView(value: packs.fraction)
                Text(packs.progressLabel)
                    .appText(.meta)
            }
        }
        .padding(.vertical, 4)
    }

    private func isReady(_ pack: VoicePack) -> Bool {
        switch pack {
        case .kokoro(let variant): return packs.isKokoroPackReady(variant)
        case .pocket(let language): return packs.isPocketPackDownloaded(language)
        case .supertonic3: return packs.isSupertonic3Downloaded
        }
    }

    private func startDownload(_ pack: VoicePack) {
        Task {
            switch pack {
            case .kokoro(let variant): await viewModel.downloadKokoroPackIfNeeded(variant: variant)
            case .pocket(let language): await viewModel.downloadPocketPackIfNeeded(language: language)
            case .supertonic3: await viewModel.downloadSupertonic3PackIfNeeded()
            }
        }
    }
}

#Preview {
    let viewModel = TTSViewModel(dependencies: DependencyContainer())
    SetupView(viewModel: viewModel, packs: viewModel.packs)
}
