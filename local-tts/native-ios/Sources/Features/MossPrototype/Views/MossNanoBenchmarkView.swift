import SwiftUI

/// Standalone benchmark screen for the MOSS-TTS-Nano evaluation (issue
/// #25) — CPU vs. CoreML+ANE via ONNX Runtime. Deliberately plain/default
/// SwiftUI styling rather than the app's dark palette, to read as a dev
/// tool rather than a shipped screen; not reachable from any tab, only
/// from Settings' "Experimental" section.
struct MossNanoBenchmarkView: View {
    @StateObject private var viewModel = MossNanoBenchmarkViewModel()

    var body: some View {
        Form {
            Section("MOSS-TTS-Nano prototype") {
                Text(
                    "Experimental ONNX Runtime pipeline, comparing plain CPU against the CoreML execution provider restricted to devices with an Apple Neural Engine. Not wired into the app's real voices yet — see issue #25."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !viewModel.isModelReady {
                Section("Models (~717 MB)") {
                    if viewModel.isDownloading {
                        ProgressView(value: viewModel.downloadProgress)
                        Text("\(Int(viewModel.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Download models") { viewModel.downloadModelsIfNeeded() }
                    }
                }
            } else {
                Section("Text") {
                    TextField("Text to synthesize", text: $viewModel.inputText, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Run") {
                    Button("Run — CPU") { viewModel.run(provider: .cpu) }
                        .disabled(viewModel.isRunning)
                    Button("Run — CoreML + ANE") { viewModel.run(provider: .coreMLANE) }
                        .disabled(viewModel.isRunning)
                    if viewModel.isRunning {
                        HStack {
                            ProgressView()
                            Text("Generating\u{2026}").foregroundStyle(.secondary)
                        }
                    }
                }

                if let cpu = viewModel.cpuResult {
                    Section("CPU result") { timingRows(cpu) }
                }
                if let coreML = viewModel.coreMLResult {
                    Section("CoreML + ANE result") { timingRows(coreML) }
                }
            }

            if let message = viewModel.statusMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("MOSS-TTS-Nano")
    }

    @ViewBuilder
    private func timingRows(_ timings: MossNanoTimings) -> some View {
        row("Prefill", String(format: "%.2fs", timings.prefillSeconds))
        row("Decode loop", String(format: "%.2fs", timings.decodeLoopSeconds))
        row("Codec decode", String(format: "%.2fs", timings.codecDecodeSeconds))
        row("Total", String(format: "%.2fs", timings.totalSeconds))
        row("Frames generated", "\(timings.frameCount)")
        row("Audio duration", String(format: "%.2fs", timings.audioDurationSeconds))
        row("Real-time factor", String(format: "%.2fx", timings.realTimeFactor))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

#Preview {
    NavigationStack { MossNanoBenchmarkView() }
}
