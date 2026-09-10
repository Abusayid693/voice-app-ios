import SwiftUI

/// Combined Kokoro + Pocket voice picker for the Write text screen — one
/// list, each voice tagged available/not-available based on whether that
/// engine's pack has been downloaded (see SetupSheet). Selecting an
/// available voice also switches `viewModel.engine` to match.
struct VoiceSettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Kokoro-ANE") {
                    ForEach(TTSViewModel.kokoroVoices, id: \.self) { name in
                        voiceRow(
                            name: name,
                            isAvailable: viewModel.isKokoroPackReady,
                            isSelected: viewModel.engine == .kokoroAne && viewModel.kokoroVoice == name
                        ) {
                            viewModel.engine = .kokoroAne
                            viewModel.kokoroVoice = name
                            dismiss()
                        }
                    }
                }
                Section("Pocket TTS") {
                    ForEach(TTSViewModel.pocketVoices, id: \.self) { name in
                        voiceRow(
                            name: name,
                            isAvailable: viewModel.isPocketPackDownloaded,
                            isSelected: viewModel.engine == .pocketTts && viewModel.pocketVoice == name
                        ) {
                            viewModel.engine = .pocketTts
                            viewModel.pocketVoice = name
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Voice")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func voiceRow(
        name: String, isAvailable: Bool, isSelected: Bool, onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack {
                Text(name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.blue)
                } else if !isAvailable {
                    Text("Not available").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .foregroundStyle(isAvailable ? .primary : .secondary)
    }
}

#Preview {
    VoiceSettingsSheet(viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
