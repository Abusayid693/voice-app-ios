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

    // MARK: - Kokoro chunk player

    @Published var kokoroChunkStates: [ChunkState] = []
    @Published var kokoroChunkIndex = 0
    @Published var isKokoroPlaying = false
    @Published var isKokoroBuffering = false

    // Append-only across multiple "Generate" taps — each tap adds more
    // chunks to the end rather than replacing what's here, so previously
    // generated audio stays in the list to be played while new audio is
    // still being produced.
    private var kokoroChunkTexts: [String] = []
    private var kokoroChunkAudio: [Data?] = []
    private var kokoroGenerationCursor = 0
    private var kokoroModelsReady = false
    private var kokoroPendingPlayIndex: Int?
    private var kokoroGenerationTask: Task<Void, Never>?
    private var kokoroPlayer: AVAudioPlayer?
    private var kokoroPlayerDelegate: KokoroChunkPlaybackDelegate?

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

    /// Entry point for the full-screen text sheet's single "Listen" button
    /// (PocketTTS has just one action; Kokoro's main screen splits Generate
    /// and Play into separate controls — this chains them so "Listen" still
    /// works as one tap: generate the current text, then play it as soon as
    /// it's ready, unless something is already playing).
    func runDownloadAndSpeak() {
        switch engine {
        case .kokoroAne:
            let startIndex = kokoroChunkTexts.count
            generateKokoro()
            if kokoroChunkTexts.count > startIndex, !isKokoroPlaying {
                playKokoroChunk(at: startIndex)
            }
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

        kokoroGenerationTask?.cancel()
        kokoroGenerationTask = nil
        kokoroPlayer?.stop()
        kokoroPlayer = nil
        kokoroPlayerDelegate = nil
        kokoroChunkTexts = []
        kokoroChunkAudio = []
        kokoroChunkStates = []
        kokoroChunkIndex = 0
        kokoroGenerationCursor = 0
        kokoroModelsReady = false
        kokoroPendingPlayIndex = nil
        isKokoroPlaying = false
        isKokoroBuffering = false
    }

    // MARK: - Kokoro: Generate (always appends new audio to the list)

    /// Chunks the current text and appends it to the (persistent, growing)
    /// playback list, then makes sure the background generation loop is
    /// running to fill in the new chunks' audio. Never clears or replaces
    /// what's already there — repeated taps just add more to play.
    func generateKokoro() {
        let chunks = KokoroTextChunker.chunk(text)
        guard !chunks.isEmpty else { return }

        kokoroChunkTexts.append(contentsOf: chunks)
        kokoroChunkAudio.append(contentsOf: Array(repeating: nil, count: chunks.count))
        kokoroChunkStates.append(contentsOf: Array(repeating: .waiting, count: chunks.count))

        ensureKokoroGenerationRunning()
    }

    /// One persistent worker loop, not one-per-Generate-tap: it drains
    /// `kokoroChunkTexts` by index and simply re-checks the count each
    /// iteration, so if `generateKokoro()` appends more while this is
    /// already running, it keeps going instead of needing to be restarted.
    private func ensureKokoroGenerationRunning() {
        guard kokoroGenerationTask == nil else { return }

        kokoroGenerationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.kokoroGenerationTask = nil }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                if !kokoroModelsReady {
                    isBusy = true
                    status = "Checking cache…"
                    let initStart = Date()
                    try await kokoroService.ensureModels(progressHandler: { progress in
                        Task { @MainActor in
                            self.applyDownloadProgress(
                                progress, phaseWeight: 0.5, fetchTotal: self.fetchEnglishKokoroTotalBytes)
                        }
                    })
                    isWarmInit = !didDownload

                    status = "Loading models…"
                    try await kokoroService.initialize()
                    initSeconds = Date().timeIntervalSince(initStart)
                    kokoroModelsReady = true
                    isBusy = false
                }

                status = "Synthesizing…"
                while kokoroGenerationCursor < kokoroChunkTexts.count {
                    let index = kokoroGenerationCursor
                    try Task.checkCancellation()
                    let data = try await kokoroService.synthesize(
                        text: kokoroChunkTexts[index], voice: Self.kokoroVoice)
                    try Task.checkCancellation()

                    kokoroChunkAudio[index] = data
                    if kokoroChunkStates[index] == .waiting {
                        kokoroChunkStates[index] = .generated
                    }
                    if kokoroPendingPlayIndex == index {
                        kokoroPendingPlayIndex = nil
                        playKokoroChunk(at: index)
                    }
                    kokoroGenerationCursor += 1
                }
                status = "Idle"
            } catch is CancellationError {
                // Cleared by a reset (e.g. switching engines) — nothing to report.
            } catch {
                status = "Error: \(error.localizedDescription)"
                isBusy = false
                isKokoroBuffering = false
            }
        }
    }

    // MARK: - Kokoro: Play (walks the accumulated list; independent of Generate)

    func toggleKokoroPlayback() {
        guard !kokoroChunkTexts.isEmpty else { return }
        if isKokoroBuffering {
            return
        } else if isKokoroPlaying {
            kokoroPlayer?.pause()
            isKokoroPlaying = false
        } else if kokoroPlayer != nil {
            kokoroPlayer?.play()
            isKokoroPlaying = true
        } else {
            playKokoroChunk(at: kokoroChunkIndex)
        }
    }

    private func playKokoroChunk(at index: Int) {
        kokoroChunkIndex = index
        guard let data = kokoroChunkAudio[index] else {
            kokoroPendingPlayIndex = index
            isKokoroBuffering = true
            return
        }
        do {
            let player = try AVAudioPlayer(data: data)
            let delegate = KokoroChunkPlaybackDelegate { [weak self] in
                Task { @MainActor in self?.advanceKokoroChunk() }
            }
            player.delegate = delegate
            kokoroPlayerDelegate = delegate
            kokoroPlayer = player

            kokoroChunkStates[index] = .playing
            isKokoroBuffering = false
            isKokoroPlaying = true
            status = "Playing chunk \(index + 1) of \(kokoroChunkTexts.count)…"
            player.play()
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func advanceKokoroChunk() {
        let finishedIndex = kokoroChunkIndex
        if kokoroChunkStates.indices.contains(finishedIndex) {
            kokoroChunkStates[finishedIndex] = .generated
        }
        let nextIndex = finishedIndex + 1
        guard nextIndex < kokoroChunkTexts.count else {
            // Reached the end of what's been queued so far — not "finished
            // forever": a later Generate call can still append more, and
            // Play will pick up from index 0 again (replay) if tapped with
            // nothing new added.
            isKokoroPlaying = false
            isKokoroBuffering = false
            status = "Idle"
            kokoroPlayer = nil
            kokoroPlayerDelegate = nil
            kokoroChunkIndex = 0
            return
        }
        playKokoroChunk(at: nextIndex)
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

/// Bridges `AVAudioPlayerDelegate`'s completion callback to a plain closure
/// so `TTSViewModel` can advance to the next chunk without conforming to
/// `NSObject` itself.
private final class KokoroChunkPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
