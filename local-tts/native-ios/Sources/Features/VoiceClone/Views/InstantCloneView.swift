import SwiftUI

/// Pushed from CreateVoiceSheet for .instantClone — record ~10s of speech
/// (a suggested passage is shown to read aloud), then the shared
/// preview/name/Clone step.
struct InstantCloneView: View {
    @ObservedObject var viewModel: VoiceCloneViewModel
    let onFinished: () -> Void

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
                VStack(spacing: 6) {
                    Text("Try reading this aloud")
                        .font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                    Text(VoiceCloneViewModel.suggestedReadingText)
                        .font(.subheadline)
                        .foregroundStyle(Color.appPrimaryText)
                        .multilineTextAlignment(.center)
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
            Button("Record") { viewModel.startRecording() }
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    NavigationStack {
        InstantCloneView(
            viewModel: VoiceCloneViewModel(dependencies: DependencyContainer()), onFinished: {})
    }
}
