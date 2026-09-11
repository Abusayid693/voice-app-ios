import SwiftUI

/// Pushed as a real page (not inside the CreateVoiceSheet modal) for
/// .instantClone — record ~10s of speech (a suggested passage is shown to
/// read aloud, with a "Try another" shuffle), then the shared
/// preview/name/Clone step.
struct InstantCloneView: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    let onFinished: () -> Void
    @State private var passageIndex = 0

    var body: some View {
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

            if !viewModel.hasRecording {
                VStack(spacing: 10) {
                    Text("Try reading this aloud")
                        .font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                    Text(currentPassage)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.appPrimaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        passageIndex =
                            (passageIndex + 1) % VoiceCloneViewModel.suggestedReadingPassages.count
                    } label: {
                        Label("Try another", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.appSecondaryText)
                }
                .padding(.horizontal, 32)
            }

            recordControls

            if viewModel.hasRecording {
                VoiceSamplePreviewSection(viewModel: viewModel, onFinished: onFinished)
            }

            Spacer()
        }
        .padding(.bottom, 20)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Instant Clone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentPassage: String {
        VoiceCloneViewModel.suggestedReadingPassages[passageIndex]
    }

    private var timerLabel: String {
        let totalSeconds = Int(viewModel.recordingDuration)
        return String(format: "0:%02d", totalSeconds)
    }

    @ViewBuilder
    private var recordControls: some View {
        if viewModel.isRecording {
            Button("Stop") { viewModel.stopRecording() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        } else if !viewModel.hasRecording {
            Button("Create Clone") { viewModel.startRecording() }
                .buttonStyle(.primary)
                .padding(.horizontal, 40)
        }
    }
}

#Preview {
    NavigationStack {
        InstantCloneView(
            viewModel: VoiceCloneViewModel(dependencies: DependencyContainer()), onFinished: {})
    }
}
