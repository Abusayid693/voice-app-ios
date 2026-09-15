import LucideSwift
import SwiftUI
import UniformTypeIdentifiers

/// Pushed from CreateVoiceSheet for .upload — pick an audio file, then the
/// shared preview/name/Clone step.
struct UploadVoiceView: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    let onFinished: () -> Void
    @State private var isFileImporterPresented = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            LucideIcon(.upload, size: 56, color: Color.appPrimaryText)

            if !viewModel.hasRecording {
                Button("Upload") { isFileImporterPresented = true }
                    .buttonStyle(.primary)
                    .padding(.horizontal, 40)
            } else {
                Text("Imported file")
                    .appText(.title)

                VoiceSamplePreviewSection(viewModel: viewModel, onFinished: onFinished)
            }

            Spacer()
        }
        .padding(.bottom, 20)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Upload File")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented, allowedContentTypes: [.audio]
        ) { result in
            if case .success(let url) = result {
                viewModel.importAudio(from: url)
            }
        }
    }
}

#Preview {
    NavigationStack {
        UploadVoiceView(
            viewModel: VoiceCloneViewModel(dependencies: DependencyContainer()), onFinished: {})
    }
}
