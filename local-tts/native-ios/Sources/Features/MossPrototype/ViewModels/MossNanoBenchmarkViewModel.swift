import AVFoundation
import Foundation

/// Drives the standalone MOSS-TTS-Nano benchmark screen (issue #25) — not
/// part of the app's real TTS engines. Owns download/run state and hands
/// UI-ready results back; `MossNanoEngineService` does the actual ONNX
/// Runtime work, per CLAUDE.md's MVVM+Services split.
@MainActor
final class MossNanoBenchmarkViewModel: ObservableObject {
    @Published var inputText =
        "Recorded sound was once impossible, yet today a small phone can speak any sentence aloud in a convincing human voice."
    @Published private(set) var isModelReady = MossNanoModelDownloader.isDownloaded()
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var cpuResult: MossNanoTimings?
    @Published private(set) var coreMLResult: MossNanoTimings?

    private var audioPlayer: AVAudioPlayer?

    func downloadModelsIfNeeded() {
        guard !isModelReady, !isDownloading else { return }
        isDownloading = true
        statusMessage = nil
        Task {
            do {
                try await MossNanoModelDownloader.ensureModels { [weak self] fraction in
                    Task { @MainActor in self?.downloadProgress = fraction }
                }
                isModelReady = true
            } catch {
                statusMessage = "Download failed: \(error.localizedDescription)"
            }
            isDownloading = false
        }
    }

    func run(provider: MossNanoExecutionProvider) {
        guard isModelReady, !isRunning else { return }
        isRunning = true
        statusMessage = nil
        let text = inputText
        Task {
            do {
                // Session creation (loading ~700MB of weights, compiling
                // the CoreML EP's partitions) happens fresh per run rather
                // than being cached across provider switches — simpler,
                // and keeps the two providers' timings from contaminating
                // each other via any shared warm state.
                let service = try MossNanoEngineService(executionProvider: provider)
                let result = try service.synthesize(text: text)
                switch provider {
                case .cpu: cpuResult = result.timings
                case .coreMLANE: coreMLResult = result.timings
                }
                play(pcm: result.pcm, sampleRate: result.sampleRate)
            } catch {
                statusMessage = "Run failed: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    private func play(pcm: [Float], sampleRate: Int) {
        guard let fileURL = try? writeWav(pcm: pcm, sampleRate: sampleRate) else { return }
        // Matches TTSViewModel's own playback setup — without this,
        // AVAudioPlayer can come up silent (respects the ring/mute switch)
        // rather than reliably routing to the speaker.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer = try? AVAudioPlayer(contentsOf: fileURL)
        audioPlayer?.play()
    }

    private func writeWav(pcm: [Float], sampleRate: Int) throws -> URL {
        var data = Data()
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let dataSize = Int32(pcm.count * 2)
        let byteRate = Int32(sampleRate) * Int32(channels) * Int32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8

        func appendString(_ string: String) { data.append(string.data(using: .ascii)!) }
        func appendInt32(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendInt16(_ value: Int16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendInt32(36 + dataSize)
        appendString("WAVE")
        appendString("fmt ")
        appendInt32(16)
        appendInt16(1)
        appendInt16(channels)
        appendInt32(Int32(sampleRate))
        appendInt32(byteRate)
        appendInt16(blockAlign)
        appendInt16(bitsPerSample)
        appendString("data")
        appendInt32(dataSize)
        for sample in pcm {
            let clamped = max(-1, min(1, sample))
            appendInt16(Int16(clamped * 32767))
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moss_nano_benchmark.wav")
        try data.write(to: url)
        return url
    }
}
