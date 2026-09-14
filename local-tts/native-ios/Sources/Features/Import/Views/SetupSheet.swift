import LucideSwift
import SwiftUI

/// Modal for downloading the two voice packs up front. Always reachable
/// from Import's "Setup" button — an already-downloaded pack simply shows
/// as done instead of offering a download button again.
struct SetupSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(VoicePack.allCases) { pack in
                        packRow(for: pack)
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                } footer: {
                    Text("Download each voice pack to make its voices available when writing.")
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Setup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
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
                    Text(pack.title).font(.subheadline).bold().foregroundStyle(Color.appPrimaryText)
                    Text(pack.subtitle).font(.caption).foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
                if isReady {
                    LucideIcon(.circleCheck, color: .green)
                } else if isDownloadingThis {
                    ProgressView()
                } else {
                    Button("Download") { startDownload(pack) }
                        .buttonStyle(.borderedProminent)
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
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText)
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
    SetupSheet(viewModel: viewModel, packs: viewModel.packs)
}
