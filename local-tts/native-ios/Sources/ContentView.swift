import AVFoundation
import FluidAudio
import SwiftUI

struct ContentView: View {
    @State private var text = "Hello from FluidAudio!"
    @State private var status = "Idle"
    @State private var isBusy = false
    @State private var initSeconds: TimeInterval?
    @State private var synthSeconds: TimeInterval?
    @State private var isWarmInit = false

    @State private var downloadFraction: Double = 0
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64?
    @State private var downloadFileProgress: String?

    private let manager = KokoroAneManager()
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Text to speak", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button(action: runDownloadAndSpeak) {
                        if isBusy {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Download & Speak")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isBusy || text.isEmpty)
                }

                Section("Status") {
                    LabeledContent("State", value: status)

                    if !isWarmInit, isBusy, initSeconds == nil {
                        ProgressView(value: downloadFraction)
                        LabeledContent("Downloaded") {
                            Text(downloadProgressLabel)
                        }
                        if let downloadFileProgress {
                            LabeledContent("Files", value: downloadFileProgress)
                        }
                    }

                    if let initSeconds {
                        LabeledContent(isWarmInit ? "Init (warm)" : "Init (cold, incl. download)") {
                            Text(String(format: "%.2fs", initSeconds))
                        }
                    }
                    if let synthSeconds {
                        LabeledContent("Synthesis") {
                            Text(String(format: "%.2fs", synthSeconds))
                        }
                    }
                }
            }
            .navigationTitle("Kokoro-ANE Test")
        }
    }

    private var downloadProgressLabel: String {
        let downloaded = Self.formatMB(downloadedBytes)
        guard let totalBytes else { return "\(downloaded) MB" }
        return "\(downloaded) / \(Self.formatMB(totalBytes)) MB"
    }

    private static func formatMB(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }

    private func runDownloadAndSpeak() {
        isBusy = true
        downloadFraction = 0
        downloadedBytes = 0
        totalBytes = nil
        downloadFileProgress = nil

        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                let wasAvailable = await manager.isAvailable()
                isWarmInit = wasAvailable

                let initStart = Date()
                if wasAvailable {
                    status = "Loading…"
                } else {
                    status = "Fetching model size…"
                    totalBytes = await fetchEnglishModelTotalBytes()

                    status = "Downloading model…"
                    // Pre-download with progress reporting, then hand off to
                    // manager.initialize() — it will find the files already
                    // cached and skip straight to the (fast) load step.
                    try await KokoroAneResourceDownloader.ensureModels(
                        variant: .english,
                        progressHandler: { [self] progress in
                            Task { @MainActor in
                                self.applyDownloadProgress(progress)
                            }
                        })
                }

                status = "Loading models…"
                try await manager.initialize()
                initSeconds = Date().timeIntervalSince(initStart)

                status = "Synthesizing…"
                let synthStart = Date()
                let data = try await manager.synthesize(text: text)
                synthSeconds = Date().timeIntervalSince(synthStart)

                status = "Playing"
                let player = try AVAudioPlayer(data: data)
                audioPlayer = player
                player.play()
                status = "Idle"
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    @MainActor
    private func applyDownloadProgress(_ progress: DownloadProgress) {
        // ensureModels() only drives the download half of FluidAudio's
        // generic 0-0.5-download/0.5-1.0-compile weighting (these .mlmodelc
        // bundles are pre-compiled, so the compile half never fires here) —
        // normalize back to a plain 0...1 download fraction.
        downloadFraction = min(1, progress.fractionCompleted / 0.5)
        if let totalBytes {
            downloadedBytes = Int64(downloadFraction * Double(totalBytes))
        }
        switch progress.phase {
        case .listing:
            status = "Listing model files…"
        case .downloading(let completedFiles, let totalFiles):
            status = "Downloading model…"
            downloadFileProgress = "\(completedFiles) / \(totalFiles)"
        case .compiling:
            status = "Compiling…"
        }
    }

    /// Sums file sizes from HuggingFace's public tree API for the English
    /// Kokoro-ANE bundle (`FluidInference/kokoro-82m-coreml/ANE`) — the SDK's
    /// own progress callback reports a fraction, not byte totals, so this is
    /// a best-effort, independent lookup purely for the "total size" display.
    private func fetchEnglishModelTotalBytes() async -> Int64? {
        guard
            let url = URL(
                string:
                    "https://huggingface.co/api/models/FluidInference/kokoro-82m-coreml/tree/main/ANE?recursive=true"
            )
        else { return nil }
        struct Entry: Decodable {
            let type: String
            let size: Int64?
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            return entries.filter { $0.type == "file" }.reduce(0) { $0 + ($1.size ?? 0) }
        } catch {
            return nil
        }
    }
}

#Preview {
    ContentView()
}
