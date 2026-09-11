import SwiftUI
import UniformTypeIdentifiers

/// Record ~10s of speech, preview it, name it, and clone it into a
/// reusable PocketTTS voice — reached from Import's "Create your own
/// voice" row or the Voices tab's "+" button.
struct RecordVoiceView: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var voiceName = ""
    @State private var isFileImporterPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "mic.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(viewModel.isRecording ? .red : Color.appPrimaryText)
                    .scaleEffect(viewModel.isRecording ? 1.08 : 1)
                    .animation(
                        viewModel.isRecording
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                        value: viewModel.isRecording)

                Text(timerLabel)
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(Color.appPrimaryText)

                recordControls

                if !viewModel.isRecording && !viewModel.hasRecording {
                    Button("Choose a file instead") { isFileImporterPresented = true }
                        .font(.subheadline)
                        .foregroundStyle(Color.appSecondaryText)
                }

                if viewModel.hasRecording {
                    TextField("Name this voice", text: $voiceName)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 40)
                }

                if let cloneErrorMessage = viewModel.cloneErrorMessage {
                    Text(cloneErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()

                Button {
                    Task {
                        await viewModel.cloneAndSave(
                            name: voiceName.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "My Voice" : voiceName)
                        if viewModel.cloneErrorMessage == nil { dismiss() }
                    }
                } label: {
                    if viewModel.isCloning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Clone Voice").bold().frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasRecording || viewModel.isCloning)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Create Your Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        viewModel.discardRecording()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented, allowedContentTypes: [.audio]
            ) { result in
                if case .success(let url) = result {
                    viewModel.importAudio(from: url)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var timerLabel: String {
        if viewModel.isImportedSample { return "Imported file" }
        let totalSeconds = Int(viewModel.recordingDuration)
        return String(format: "0:%02d", totalSeconds)
    }

    @ViewBuilder
    private var recordControls: some View {
        if viewModel.isRecording {
            Button("Stop") { viewModel.stopRecording() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        } else if viewModel.hasRecording {
            HStack(spacing: 16) {
                Button {
                    viewModel.previewRecording()
                } label: {
                    Label(
                        viewModel.isPreviewingRecording ? "Playing…" : "Play",
                        systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isPreviewingRecording)

                Button(viewModel.isImportedSample ? "Choose Different File" : "Re-record") {
                    viewModel.discardRecording()
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button("Record") { viewModel.startRecording() }
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    RecordVoiceView(viewModel: VoiceCloneViewModel(dependencies: DependencyContainer()))
}
