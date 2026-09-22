import LucideSwift
import SwiftUI

/// Shared Kokoro + Pocket + Supertonic-3 voice picker. Write Text presents
/// the complete catalog; a reader can restrict it to its persisted engine
/// and receive the selected voice through `onVoiceSelected`.
struct VoiceSettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    private let restrictedEngine: Engine?
    private let selectedVoiceName: String?
    private let onVoiceSelected: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: TTSViewModel,
        packs: VoicePackStore,
        voiceCloneViewModel: VoiceCloneViewModel,
        restrictedEngine: Engine? = nil,
        selectedVoiceName: String? = nil,
        onVoiceSelected: ((String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.packs = packs
        self.voiceCloneViewModel = voiceCloneViewModel
        self.restrictedEngine = restrictedEngine
        self.selectedVoiceName = selectedVoiceName
        self.onVoiceSelected = onVoiceSelected
    }

    var body: some View {
        NavigationStack {
            List {
                if shows(.pocketTts), !voiceCloneViewModel.clonedVoices.isEmpty {
                    Section("My Voices") {
                        ForEach(voiceCloneViewModel.clonedVoices) { clonedVoice in
                            voiceRow(
                                name: clonedVoice.name,
                                isAvailable: true,
                                isSelected: isSelected(
                                    clonedVoice.name,
                                    fallback: viewModel.engine == .pocketTts
                                        && viewModel.selectedClonedVoice?.id == clonedVoice.id)
                            ) {
                                viewModel.engine = .pocketTts
                                // Match the manager/service the voice was
                                // actually cloned with — generating always
                                // routes through the current pocketLanguage.
                                viewModel.pocketLanguage = clonedVoice.language
                                viewModel.selectedClonedVoice = clonedVoice
                                finishSelection(clonedVoice.name)
                            }
                        }
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                }

                if shows(.kokoroAne) {
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
                                isSelected: isSelected(
                                    name,
                                    fallback: viewModel.engine == .kokoroAne
                                        && viewModel.kokoroVoice == name)
                            ) {
                                viewModel.engine = .kokoroAne
                                viewModel.kokoroVoice = name
                                viewModel.selectedClonedVoice = nil
                                finishSelection(name)
                            }
                        }
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                }

                if shows(.pocketTts) {
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
                                isSelected: isSelected(
                                    name,
                                    fallback: viewModel.engine == .pocketTts
                                        && viewModel.pocketVoice == name
                                        && viewModel.selectedClonedVoice == nil)
                            ) {
                                viewModel.engine = .pocketTts
                                viewModel.pocketVoice = name
                                viewModel.selectedClonedVoice = nil
                                finishSelection(name)
                            }
                        }
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                }

                // Two independent pickers, unlike Kokoro/Pocket's one —
                // Supertonic-3's voice and language aren't tied together
                // (the same voice speaks any language, chosen separately).
                if shows(.supertonic3) {
                    Section("Supertonic-3") {
                        Picker("Language", selection: $viewModel.supertonicLanguage) {
                            ForEach(SupertonicLanguage.all) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .tint(Color.appPrimaryText)

                        ForEach(SupertonicVoice.allCases) { voice in
                            voiceRow(
                                name: voice.displayName,
                                isAvailable: packs.isSupertonic3Downloaded,
                                isSelected: isSelected(
                                    voice.displayName,
                                    alternate: voice.rawValue,
                                    fallback: viewModel.engine == .supertonic3
                                        && viewModel.supertonicVoice == voice)
                            ) {
                                viewModel.engine = .supertonic3
                                viewModel.supertonicVoice = voice
                                viewModel.selectedClonedVoice = nil
                                finishSelection(voice.displayName)
                            }
                        }
                    }
                    .listRowBackground(Color.appSecondaryBackground)
                }
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
        .onAppear(perform: synchronizeRestrictedSelection)
    }

    private func shows(_ engine: Engine) -> Bool {
        restrictedEngine == nil || restrictedEngine == engine
    }

    private func isSelected(
        _ name: String, alternate: String? = nil, fallback: @autoclosure () -> Bool
    ) -> Bool {
        guard restrictedEngine != nil else { return fallback() }
        return selectedVoiceName == name || selectedVoiceName == alternate
    }

    private func finishSelection(_ voiceName: String) {
        onVoiceSelected?(voiceName)
        dismiss()
    }

    /// Saved Kokoro projects can use a non-English catalog. Open the shared
    /// picker on that catalog so the active voice is visible immediately.
    private func synchronizeRestrictedSelection() {
        guard restrictedEngine == .kokoroAne,
              let selectedVoiceName,
              let variant = VoiceCatalog.variant(forCode: selectedVoiceName)
        else { return }
        viewModel.kokoroVariant = variant
    }

    private func voiceRow(
        name: String, isAvailable: Bool, isSelected: Bool, onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack {
                Text(name).appText(isAvailable ? .rowTitle : .rowTitleMuted)
                Spacer()
                if isSelected {
                    LucideIcon(.check, size: 15, color: .blue)
                } else if !isAvailable {
                    Text("Not available").appText(.labelDim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    VoiceSettingsSheet(
        viewModel: viewModel, packs: viewModel.packs,
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies))
}
