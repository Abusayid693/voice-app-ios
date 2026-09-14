import LucideSwift
import SwiftUI

/// Combined Kokoro + Pocket voice picker for the Write text screen — one
/// list, each voice tagged available/not-available based on whether that
/// engine's pack has been downloaded (see SetupSheet). Selecting an
/// available voice also switches `viewModel.engine` to match.
struct VoiceSettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !voiceCloneViewModel.clonedVoices.isEmpty {
                    Section("My Voices") {
                        ForEach(voiceCloneViewModel.clonedVoices) { clonedVoice in
                            voiceRow(
                                name: clonedVoice.name,
                                isAvailable: true,
                                isSelected: viewModel.engine == .pocketTts
                                    && viewModel.selectedClonedVoice?.id == clonedVoice.id
                            ) {
                                viewModel.engine = .pocketTts
                                // Match the manager/service the voice was
                                // actually cloned with — generating always
                                // routes through the current pocketLanguage.
                                viewModel.pocketLanguage = clonedVoice.language
                                viewModel.selectedClonedVoice = clonedVoice
                                dismiss()
                            }
                        }
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                }

                Section("Kokoro-ANE") {
                    Picker("Language", selection: $viewModel.kokoroVariant) {
                        ForEach(KokoroVariant.allCases) { variant in
                            Text(variant.displayName).tag(variant)
                        }
                    }
                    .tint(Color.appPrimaryText)

                    ForEach(TTSViewModel.kokoroVoices(for: viewModel.kokoroVariant), id: \.self) { name in
                        voiceRow(
                            name: name,
                            isAvailable: packs.isKokoroPackReady(viewModel.kokoroVariant),
                            isSelected: viewModel.engine == .kokoroAne && viewModel.kokoroVoice == name
                        ) {
                            viewModel.engine = .kokoroAne
                            viewModel.kokoroVoice = name
                            viewModel.selectedClonedVoice = nil
                            dismiss()
                        }
                    }
                }
                .listRowBackground(Color.appSecondaryBackground)

                Section("Pocket TTS") {
                    Picker("Language", selection: $viewModel.pocketLanguage) {
                        ForEach(PocketLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .tint(Color.appPrimaryText)

                    ForEach(TTSViewModel.pocketVoices, id: \.self) { name in
                        voiceRow(
                            name: name,
                            isAvailable: packs.isPocketPackDownloaded(viewModel.pocketLanguage),
                            isSelected: viewModel.engine == .pocketTts && viewModel.pocketVoice == name
                                && viewModel.selectedClonedVoice == nil
                        ) {
                            viewModel.engine = .pocketTts
                            viewModel.pocketVoice = name
                            viewModel.selectedClonedVoice = nil
                            dismiss()
                        }
                    }
                }
                .listRowBackground(Color.appSecondaryBackground)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Voice")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func voiceRow(
        name: String, isAvailable: Bool, isSelected: Bool, onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack {
                Text(name)
                Spacer()
                if isSelected {
                    LucideIcon(.check, size: 15, color: .blue)
                } else if !isAvailable {
                    Text("Not available").font(.caption).foregroundStyle(Color.appTertiaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .foregroundStyle(isAvailable ? Color.appPrimaryText : Color.appSecondaryText)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    VoiceSettingsSheet(
        viewModel: viewModel, packs: viewModel.packs,
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies))
}
