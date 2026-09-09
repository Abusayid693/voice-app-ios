import AVFoundation
import Combine
import FluidAudio

@MainActor
final class TTSViewModel: ObservableObject {
    // af_heart is the only voice published in the ANE HF repo — the SDK's
    // own docs confirm this is a hard model-conversion constraint (the
    // compiled PostAlbert/Prosody/Noise/Vocoder stages are tied to this
    // voice's embedding), not just a missing download, so there's nothing
    // else worth offering here.
    static let kokoroVoice = "af_heart"

    // All 26 published in constants_bin/ for the English v2.1 pack — these
    // are real, no missing-asset gap like the Kokoro voices above.
    static let pocketVoices = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "eponine", "estelle", "eve", "fantine", "george", "giovanni",
        "jane", "javert", "jean", "juergen", "lola", "marius", "mary", "michael",
        "paul", "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]

    @Published var engine: Engine = .kokoroAne
    @Published var pocketVoice = "alba"
    @Published var text = "Hello from FluidAudio!"
    @Published var status = "Idle"
    @Published var isBusy = false
    @Published var initSeconds: TimeInterval?
    @Published var synthSeconds: TimeInterval?
    @Published var isWarmInit = false

    @Published var downloadFraction: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64?
    @Published var downloadFileProgress: String?
    // Set only once a real download event fires (see applyDownloadProgress).
    // Models persist on disk across app launches (FluidAudio caches them in
    // Application Support), so ensureModels() is cheap and network-free on
    // a fresh launch even though nothing is loaded into this process's RAM
    // yet — gating the download UI on this instead of an in-memory
    // "isAvailable" flag keeps it from showing a fake "Downloading…" for
    // what's actually just a fast on-disk load.
    @Published var didDownload = false

    @Published var timeToFirstAudio: TimeInterval?
    @Published var streamChunkProgress: String?
    @Published var isTextSheetPresented = false

    private let kokoroService: KokoroEngineService
    private let pocketService: PocketEngineService
    private var audioPlayer: AVAudioPlayer?

    init(dependencies: DependencyContainer) {
        kokoroService = KokoroEngineService(manager: dependencies.kokoroManager)
        pocketService = PocketEngineService(
            manager: dependencies.pocketManager,
            audioEngine: dependencies.audioEngine,
            playerNode: dependencies.playerNode,
            streamFormat: dependencies.streamFormat)
    }

    var downloadProgressLabel: String {
        let downloaded = Self.formatMB(downloadedBytes)
        guard let totalBytes else { return "\(downloaded) MB" }
        return "\(downloaded) / \(Self.formatMB(totalBytes)) MB"
    }

    private static func formatMB(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }

    func runDownloadAndSpeak() {
        switch engine {
        case .kokoroAne:
            runKokoroAne()
        case .pocketTts:
            runPocketTts()
        }
    }

    private func resetRunState() {
        stopAllPlayback()
        isBusy = true
        downloadFraction = 0
        downloadedBytes = 0
        totalBytes = nil
        downloadFileProgress = nil
        initSeconds = nil
        synthSeconds = nil
        timeToFirstAudio = nil
        streamChunkProgress = nil
        didDownload = false
    }

    private func stopAllPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        pocketService.stopPlayback()
    }

    private func runKokoroAne() {
        resetRunState()
        let voice = Self.kokoroVoice

        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                status = "Checking cache…"
                let initStart = Date()
                try await kokoroService.ensureModels(progressHandler: { progress in
                    Task { @MainActor in
                        // Repo downloads reserve 0-0.5 of the fraction for a
                        // CoreML compile phase that never fires for these
                        // pre-compiled .mlmodelc bundles.
                        self.applyDownloadProgress(
                            progress, phaseWeight: 0.5, fetchTotal: self.fetchEnglishKokoroTotalBytes)
                    }
                })
                isWarmInit = !didDownload

                status = "Loading models…"
                try await kokoroService.initialize()
                initSeconds = Date().timeIntervalSince(initStart)

                status = "Synthesizing…"
                let synthStart = Date()
                let data = try await kokoroService.synthesize(text: text, voice: voice)
                synthSeconds = Date().timeIntervalSince(synthStart)

                try playWav(data)
                status = "Idle"
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private func runPocketTts() {
        resetRunState()
        let voice = pocketVoice
        let inputText = text

        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                status = "Checking cache…"
                let initStart = Date()
                try await pocketService.ensureModels(progressHandler: { progress in
                    Task { @MainActor in
                        self.applyDownloadProgress(
                            progress, phaseWeight: 1.0, fetchTotal: self.fetchPocketTtsTotalBytes)
                    }
                })
                isWarmInit = !didDownload

                status = "Loading models…"
                try await pocketService.initialize()
                initSeconds = Date().timeIntervalSince(initStart)

                status = "Synthesizing (streaming)…"
                try pocketService.preparePlayback()

                let synthStart = Date()
                let stream = try await pocketService.synthesizeStreaming(text: inputText, voice: voice)
                var receivedFirstFrame = false
                for try await frame in stream {
                    if !receivedFirstFrame {
                        receivedFirstFrame = true
                        timeToFirstAudio = Date().timeIntervalSince(synthStart)
                        status = "Playing (streaming)…"
                    }
                    streamChunkProgress = "\(frame.chunkIndex + 1) / \(frame.chunkCount)"
                    pocketService.schedule(frame)
                }
                synthSeconds = Date().timeIntervalSince(synthStart)
                status = "Idle"
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private func playWav(_ data: Data) throws {
        status = "Playing"
        let player = try AVAudioPlayer(data: data)
        audioPlayer = player
        player.play()
    }

    private func applyDownloadProgress(
        _ progress: DownloadProgress, phaseWeight: Double, fetchTotal: @escaping () async -> Int64?
    ) {
        if !didDownload {
            didDownload = true
            Task { @MainActor in totalBytes = await fetchTotal() }
        }
        downloadFraction = min(1, progress.fractionCompleted / phaseWeight)
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
    private func fetchEnglishKokoroTotalBytes() async -> Int64? {
        await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url: "https://huggingface.co/api/models/FluidInference/kokoro-82m-coreml/tree/main/ANE?recursive=true",
            matching: { _ in true })
    }

    /// Same idea, for PocketTTS's English v2.1 pack — but that directory also
    /// holds the GPU-placement/int8 variants, the MLState package, and the
    /// uncompiled `.mlpackage` sources, none of which `ensureModels(placement:
    /// .ane)` actually downloads. Filtering to just the components that call
    /// fetches keeps the total honest.
    private func fetchPocketTtsTotalBytes() async -> Int64? {
        let required = [
            "v2.1/english/cond_prefill_ane.mlmodelc/",
            "v2.1/english/flowlm_step_ane.mlmodelc/",
            "v2.1/english/flow_decoder_fused.mlmodelc/",
            "v2.1/english/mimi_decoder.mlmodelc/",
            "v2.1/english/constants_bin/",
        ]
        return await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url: "https://huggingface.co/api/models/FluidInference/pocket-tts-coreml/tree/main/v2.1/english?recursive=true",
            matching: { path in required.contains { path.hasPrefix($0) } })
    }
}
