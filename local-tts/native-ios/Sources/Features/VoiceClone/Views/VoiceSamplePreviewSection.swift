import SwiftUI

/// Preview/name/Clone UI shown once a sample exists (recorded or
/// imported) — shared by InstantCloneView and UploadVoiceView so neither
/// duplicates this step. Caller is responsible for only showing this once
/// `viewModel.hasRecording` is true.
struct VoiceSamplePreviewSection: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    let onFinished: () -> Void
    @State private var voiceName = ""

    var body: some View {
        VStack(spacing: 20) {
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

            TextField("Name this voice", text: $voiceName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)

            if let cloneErrorMessage = viewModel.cloneErrorMessage {
                Text(cloneErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                Task {
                    await viewModel.cloneAndSave(
                        name: voiceName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? "My Voice" : voiceName)
                    if viewModel.cloneErrorMessage == nil { onFinished() }
                }
            } label: {
                if viewModel.isCloning {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Clone Voice").bold().frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isCloning)
            .padding(.horizontal, 40)
        }
    }
}
