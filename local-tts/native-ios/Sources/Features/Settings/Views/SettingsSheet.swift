import LucideSwift
import SwiftUI

/// App settings — reached through Home's persistent trailing gear. Setup is
/// a normal destination; Voice Packs / Storage remain read-only views of
/// real on-disk state, and About reports the bundle version (see issue #9).
struct SettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    let readingStats: ReadingStatsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SetupView(viewModel: viewModel, packs: viewModel.packs)
                    } label: {
                        row(title: "Setup", icon: .circleArrowDown)
                    }
                    NavigationLink {
                        VoicePacksView(viewModel: viewModel, packs: viewModel.packs)
                    } label: {
                        row(title: "Voice Packs", icon: .packageIcon)
                    }
                    NavigationLink {
                        StorageView(
                            viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                            packs: viewModel.packs)
                    } label: {
                        row(title: "Storage", icon: .hardDrive)
                    }
                    NavigationLink {
                        ReadingStatsView(readingStats: readingStats)
                    } label: {
                        row(title: "Reading Stats", icon: .chartColumn)
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        row(title: "About", icon: .info)
                    }
                }
                .listRowBackground(Color.appSecondaryBackground)

                Section {
                    OpenSourceCard()
                        .listRowBackground(Color.appBackground)
                        .listRowInsets(EdgeInsets())
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(title: String, icon: LucideIconName) -> some View {
        Label {
            Text(title).appText(.rowTitle)
        } icon: {
            LucideIcon(icon, color: Color.appPrimaryText)
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    SettingsSheet(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        readingStats: dependencies.readingStatsStore)
}
