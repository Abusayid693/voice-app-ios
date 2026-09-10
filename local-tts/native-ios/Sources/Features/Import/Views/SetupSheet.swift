import SwiftUI

/// Modal for downloading the two voice packs up front. Always reachable
/// from Import's "Setup" button — an already-downloaded pack simply shows
/// as done instead of offering a download button again.
struct SetupSheet: View {
    @ObservedObject var viewModel: TTSViewModel
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.title).font(.subheadline).bold().foregroundStyle(Color.appPrimaryText)
                    Text(pack.subtitle).font(.caption).foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
                if isReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if viewModel.isBusy {
                    ProgressView()
                } else {
                    Button("Download") { startDownload(pack) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if viewModel.isBusy, !isReady {
                ProgressView(value: viewModel.downloadFraction)
                Text(viewModel.downloadProgressLabel)
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func isReady(_ pack: VoicePack) -> Bool {
        switch pack {
        case .kokoro: return viewModel.isKokoroPackReady
        case .pocket: return viewModel.isPocketPackDownloaded
        }
    }

    private func startDownload(_ pack: VoicePack) {
        Task {
            switch pack {
            case .kokoro: await viewModel.downloadKokoroPackIfNeeded()
            case .pocket: await viewModel.downloadPocketPackIfNeeded()
            }
        }
    }
}

#Preview {
    SetupSheet(viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
