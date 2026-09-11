import SwiftUI

/// App settings — reached via the gear icon on Import, presented the same
/// way as SetupSheet (a plain `.sheet`, dark theme, "Done" to dismiss).
/// Voice Packs / Storage report real on-disk pack/size data; About reports
/// the real bundle version (see issue #9).
struct SettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        VoicePacksView(viewModel: viewModel)
                    } label: {
                        row(title: "Voice Packs", systemImage: "shippingbox.fill")
                    }
                    NavigationLink {
                        StorageView(viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel)
                    } label: {
                        row(title: "Storage", systemImage: "internaldrive.fill")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        row(title: "About", systemImage: "info.circle.fill")
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

    private func row(title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(Color.appPrimaryText)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Color.appPrimaryText)
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    SettingsSheet(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies))
}
