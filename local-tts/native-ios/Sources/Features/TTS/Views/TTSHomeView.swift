import LucideSwift
import SwiftUI

struct TTSHomeView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var packs: VoicePackStore

    // Kokoro playback keeps running after isBusy drops back to false (that
    // only covers the download/init phase) — lock engine/voice switching
    // while any track is actively playing or buffering, not just during
    // the initial setup.
    private var isEngineLocked: Bool {
        viewModel.isBusy || viewModel.kokoroGenerations.contains { $0.isPlaying || $0.isBuffering }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine") {
                    Picker("Engine", selection: $viewModel.engine) {
                        ForEach(Engine.allCases, id: \.self) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isEngineLocked)
                }

                Section("Voice") {
                    switch viewModel.engine {
                    case .kokoroAne:
                        Picker("Voice", selection: $viewModel.kokoroVoice) {
                            ForEach(TTSViewModel.kokoroVoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(isEngineLocked)
                    case .pocketTts:
                        Picker("Voice", selection: $viewModel.pocketVoice) {
                            ForEach(TTSViewModel.pocketVoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(isEngineLocked)
                    case .supertonic3:
                        Picker("Language", selection: $viewModel.supertonicLanguage) {
                            ForEach(SupertonicLanguage.all) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .disabled(isEngineLocked)
                        Picker("Voice", selection: $viewModel.supertonicVoice) {
                            ForEach(SupertonicVoice.allCases) { voice in
                                Text(voice.displayName).tag(voice)
                            }
                        }
                        .disabled(isEngineLocked)
                    }
                }

                Section("Text") {
                    Button {
                        viewModel.isTextSheetPresented = true
                    } label: {
                        HStack {
                            Text(viewModel.text.isEmpty ? "Tap to enter text" : viewModel.text)
                                .foregroundStyle(viewModel.text.isEmpty ? .secondary : .primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            LucideIcon(.chevronRight, size: 12)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if viewModel.engine == .kokoroAne {
                        Button(action: { viewModel.generateKokoro() }) {
                            if viewModel.isBusy {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Generate")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(viewModel.text.isEmpty)
                    }
                }

                Section {
                    switch viewModel.engine {
                    case .kokoroAne:
                        KokoroGenerationListView(viewModel: viewModel)
                    case .pocketTts, .supertonic3:
                        Button(action: viewModel.runDownloadAndSpeak) {
                            if viewModel.isBusy {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Download & Speak")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(viewModel.isBusy || viewModel.text.isEmpty)
                    }
                }

                Section("Status") {
                    LabeledContent("State", value: viewModel.status)

                    if packs.didDownload, viewModel.isBusy, viewModel.initSeconds == nil {
                        ProgressView(value: packs.fraction)
                        LabeledContent("Downloaded") {
                            Text(packs.progressLabel)
                        }
                        if let downloadFileProgress = packs.fileProgress {
                            LabeledContent("Files", value: downloadFileProgress)
                        }
                    }

                    if let initSeconds = viewModel.initSeconds {
                        LabeledContent(viewModel.isWarmInit ? "Init (warm)" : "Init (cold, incl. download)") {
                            Text(String(format: "%.2fs", initSeconds))
                        }
                    }
                    if let timeToFirstAudio = viewModel.timeToFirstAudio {
                        LabeledContent("Time to first audio") {
                            Text(String(format: "%.2fs", timeToFirstAudio))
                        }
                    }
                    if let streamChunkProgress = viewModel.streamChunkProgress {
                        LabeledContent("Chunk", value: streamChunkProgress)
                    }
                    if let synthSeconds = viewModel.synthSeconds {
                        LabeledContent("Synthesis") {
                            Text(String(format: "%.2fs", synthSeconds))
                        }
                    }
                }
            }
            .navigationTitle("FluidAudio TTS Test")
        }
        .fullScreenCover(isPresented: $viewModel.isTextSheetPresented) {
            TextEntrySheet(
                text: $viewModel.text,
                isBusy: viewModel.isBusy,
                onListen: viewModel.runDownloadAndSpeak,
                onClose: { viewModel.isTextSheetPresented = false }
            )
        }
    }
}

#Preview {
    let viewModel = TTSViewModel(dependencies: DependencyContainer())
    TTSHomeView(viewModel: viewModel, packs: viewModel.packs)
}
