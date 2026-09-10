import AVFoundation
import Combine
import FluidAudio

@MainActor
final class TTSViewModel: ObservableObject {
    // All 28 standard Kokoro-82M English voices. FluidAudio's own hosted
    // ANE repo only publishes af_heart (a real model-conversion
    // constraint, not just a missing download — see ENG_CONTEXT.md), but
    // a custom from-scratch conversion (laishere/kokoro-coreml, bundled
    // via DependencyContainer's CustomKokoroModel) confirmed the rest
    // genuinely work once paired with FluidAudio's real
    // KokoroNoise_v2/KokoroTail_v2 stages — our own stock conversion of
    // those two specifically had audible pitch/loudness bugs.
    static let kokoroVoices = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    // All 26 published in constants_bin/ for the English v2.1 pack — these
    // are real, no missing-asset gap like the Kokoro voices above.
    static let pocketVoices = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "eponine", "estelle", "eve", "fantine", "george", "giovanni",
        "jane", "javert", "jean", "juergen", "lola", "marius", "mary", "michael",
        "paul", "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]

    @Published var engine: Engine = .kokoroAne
    // Changing voice mid-session would otherwise mix voices across
    // generations already in the list — clear everything so a voice
    // switch always starts clean.
    @Published var kokoroVoice = "af_heart" {
        didSet {
            guard oldValue != kokoroVoice else { return }
            stopAllPlayback()
        }
    }
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

    // MARK: - Import screen: voice-pack setup + new sheet flags

    // True once the bundled CustomKokoroModel/ was found and copied into
    // Application Support (see DependencyContainer) — for virtually every
    // install this is already true the instant TTSViewModel exists, since
    // the copy happens synchronously before any UI shows. Only changes
    // afterward in the rare case that bundle copy failed and
    // downloadKokoroPackIfNeeded() later succeeds.
    @Published var isKokoroPackReady: Bool
    // Unlike Kokoro, PocketTTS has no bundled fallback — this reflects a
    // real ~500MB network download the user must opt into via Setup.
    // Persisted so a relaunch doesn't forget it's already downloaded (the
    // SDK has no cheap, side-effect-free "is this on disk" check to ask
    // instead — see downloadPocketPackIfNeeded()).
    @Published var isPocketPackDownloaded: Bool

    // Separate from isTextSheetPresented (the Home tab's own sheet flag) so
    // the two tabs' modals don't fight over one bool.
    @Published var isSetupPresented = false
    @Published var isWriteTextPresented = false
    @Published var isVoiceSettingsPresented = false

    private static let pocketPackDownloadedDefaultsKey = "pocketPackDownloaded"

    // MARK: - Import screen: voice preview playback (bundled clips, no synthesis)

    // Which voice (if any) is currently playing its preview clip — drives
    // the preview sheet's play/pause icon.
    @Published private(set) var previewingVoiceID: String?
    // 0...1 playback position, and a 0...1 normalized live audio level
    // (from AVAudioPlayer metering) — the preview sheet's progress track
    // and the cover art's audio-reactive pulse bind to these directly.
    @Published private(set) var previewProgress: Double = 0
    @Published private(set) var previewLevel: Double = 0
    // Deliberately separate from kokoroPlayer/pocketService's engine — a
    // preview never touches either engine's state, so it can't collide
    // with an in-progress "Write text" generation.
    private var previewPlayer: AVAudioPlayer?
    private var previewPlayerDelegate: PreviewPlaybackDelegate?
    private var previewMeterTask: Task<Void, Never>?

    // MARK: - Kokoro: one independent track per "Generate" tap

    // Append-only, like a playlist — each Generate tap adds a new track
    // rather than merging into an existing one, so past generations stay
    // in the list, each with its own play button.
    @Published var kokoroGenerations: [KokoroGeneration] = []
    @Published var kokoroActiveGenerationID: KokoroGeneration.ID?

    private var kokoroModelsReady = false
    private var kokoroPendingPlay: (generationID: KokoroGeneration.ID, chunkIndex: Int)?
    private var kokoroGenerationTask: Task<Void, Never>?
    private var kokoroPlayer: AVAudioPlayer?
    private var kokoroPlayerDelegate: KokoroChunkPlaybackDelegate?

    private let kokoroService: KokoroEngineService
    private let pocketService: PocketEngineService
    private var audioPlayer: AVAudioPlayer?

    init(dependencies: DependencyContainer) {
        kokoroService = KokoroEngineService(
            manager: dependencies.kokoroManager, directory: dependencies.kokoroModelDirectory)
        pocketService = PocketEngineService(
            manager: dependencies.pocketManager,
            audioEngine: dependencies.audioEngine,
            playerNode: dependencies.playerNode,
            streamFormat: dependencies.streamFormat)
        isKokoroPackReady = dependencies.isKokoroPackBundled
        isPocketPackDownloaded = UserDefaults.standard.bool(
            forKey: Self.pocketPackDownloadedDefaultsKey)
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
    /// works as one tap: generate the current text as a new track, then
    /// play it as soon as it's ready).
    func runDownloadAndSpeak() {
        switch engine {
        case .kokoroAne:
            if let newID = generateKokoro() {
                play(generationID: newID)
            }
        case .pocketTts:
            runPocketTts()
        }
    }

    // MARK: - Import screen: Setup sheet actions

    /// Only meaningfully does anything if the bundled-copy step in
    /// DependencyContainer failed (isKokoroPackReady already false) — the
    /// common case is already ready before this could ever be called, since
    /// that copy happens synchronously at container init.
    func downloadKokoroPackIfNeeded() async {
        guard !isKokoroPackReady else { return }
        status = "Downloading Kokoro pack…"
        isBusy = true
        defer { isBusy = false }
        do {
            try await kokoroService.ensureModels(progressHandler: { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyDownloadProgress(
                        progress, phaseWeight: 1.0, fetchTotal: self.fetchEnglishKokoroTotalBytes)
                }
            })
            try await kokoroService.initialize()
            isKokoroPackReady = true
            status = "Idle"
        } catch {
            status = "Kokoro pack download failed: \(error.localizedDescription)"
        }
    }

    /// PocketTTS has no bundled fallback, so this is a real ~500MB network
    /// download the user opts into from the Setup sheet. On success, the
    /// "already downloaded" flag is persisted — there's no cheap on-disk
    /// check to ask the SDK instead (see isPocketPackDownloaded's comment).
    func downloadPocketPackIfNeeded() async {
        guard !isPocketPackDownloaded else { return }
        status = "Downloading Pocket TTS pack…"
        isBusy = true
        defer { isBusy = false }
        do {
            try await pocketService.ensureModels(progressHandler: { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyDownloadProgress(
                        progress, phaseWeight: 1.0, fetchTotal: self.fetchPocketTtsTotalBytes)
                }
            })
            try await pocketService.initialize()
            isPocketPackDownloaded = true
            UserDefaults.standard.set(true, forKey: Self.pocketPackDownloadedDefaultsKey)
            status = "Idle"
        } catch {
            status = "Pocket TTS pack download failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Import screen: voice preview playback

    /// Plays (or stops, if already playing) a voice's bundled preview clip
    /// — pure file playback, no synthesis, so this never touches
    /// kokoroService/pocketService and can't collide with an in-progress
    /// "Write text" generation. No-ops if the clip isn't bundled yet (e.g.
    /// Pocket voices before their pass — see ENG_CONTEXT.md).
    func togglePreview(voiceName: String, engine: Engine) {
        let wasPlayingThisVoice = previewingVoiceID == voiceName
        stopPreview()
        guard !wasPlayingThisVoice else { return }

        let subdirectory = "VoicePreviews/\(engine == .kokoroAne ? "Kokoro" : "Pocket")"
        guard let url = Bundle.main.url(forResource: voiceName, withExtension: "wav", subdirectory: subdirectory)
        else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.isMeteringEnabled = true
            let delegate = PreviewPlaybackDelegate { [weak self] in
                Task { @MainActor in
                    guard let self, self.previewingVoiceID == voiceName else { return }
                    self.stopPreview()
                }
            }
            player.delegate = delegate
            previewPlayerDelegate = delegate
            previewPlayer = player
            previewingVoiceID = voiceName
            player.play()
            startPreviewMetering(for: player)
        } catch {
            previewingVoiceID = nil
        }
    }

    /// Stops whatever preview is playing (if any) and resets the sheet's
    /// progress/level state — called both when the user explicitly stops
    /// and when a clip finishes on its own.
    func stopPreview() {
        previewMeterTask?.cancel()
        previewMeterTask = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewPlayerDelegate = nil
        previewingVoiceID = nil
        previewProgress = 0
        previewLevel = 0
    }

    /// Polls AVAudioPlayer's metering ~15 times a second while the preview
    /// plays, translating raw dB into a 0...1 level the cover art's
    /// scale/opacity pulse binds to, plus 0...1 playback progress for the
    /// track. Exits on its own once the player stops (finished or replaced).
    private func startPreviewMetering(for player: AVAudioPlayer) {
        previewMeterTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.previewPlayer === player, player.isPlaying {
                player.updateMeters()
                self.previewLevel = Self.normalizedLevel(fromDecibels: player.averagePower(forChannel: 0))
                self.previewProgress = player.duration > 0 ? player.currentTime / player.duration : 0
                try? await Task.sleep(nanoseconds: 66_000_000)
            }
        }
    }

    /// AVAudioPlayer's metering reports roughly -160 (silence) to 0 dB
    /// (peak) — clamping to a much narrower, perceptually-useful floor
    /// (typical speech rarely gets near 0 dB) keeps the pulse visible
    /// instead of pinned near zero.
    private static func normalizedLevel(fromDecibels power: Float) -> Double {
        let floorDb: Float = -50
        let clamped = max(power, floorDb)
        return Double((clamped - floorDb) / -floorDb)
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
        kokoroGenerations = []
        kokoroActiveGenerationID = nil
        kokoroModelsReady = false
        kokoroPendingPlay = nil
    }

    // MARK: - Kokoro: Generate (always creates a new, independent track)

    /// Chunks the current text into a new `KokoroGeneration` (its own
    /// track, like a new song in a playlist — never merged into an
    /// existing one) and appends it to the list, then makes sure the
    /// background worker is running to fill in its audio. Returns the new
    /// track's id, or nil if the text was empty.
    @discardableResult
    func generateKokoro() -> KokoroGeneration.ID? {
        let chunks = KokoroTextChunker.chunk(text)
        guard !chunks.isEmpty else { return nil }

        let generation = KokoroGeneration(
            text: text,
            chunkTexts: chunks,
            chunkAudio: Array(repeating: nil, count: chunks.count),
            chunkStates: Array(repeating: .waiting, count: chunks.count))
        kokoroGenerations.append(generation)

        ensureKokoroGenerationRunning()
        return generation.id
    }

    /// One persistent worker, not one-per-Generate-tap: each iteration
    /// finds the next not-yet-generated chunk across *all* tracks in
    /// creation order and synthesizes it, so a Generate tap while this is
    /// already running just adds more work to the same loop instead of
    /// needing to be restarted.
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
                while let next = nextPendingKokoroChunk() {
                    try Task.checkCancellation()
                    let (genIndex, chunkIndex) = next
                    let chunkText = kokoroGenerations[genIndex].chunkTexts[chunkIndex]
                    let generationID = kokoroGenerations[genIndex].id

                    do {
                        // Safe to read kokoroVoice live: a voice change
                        // always cancels this task and clears every track
                        // first (see kokoroVoice's didSet), so every chunk
                        // still in flight here was queued under the
                        // currently-selected voice.
                        let data = try await kokoroService.synthesize(text: chunkText, voice: kokoroVoice)
                        kokoroGenerations[genIndex].chunkAudio[chunkIndex] = data
                        if kokoroGenerations[genIndex].chunkStates[chunkIndex] == .waiting {
                            kokoroGenerations[genIndex].chunkStates[chunkIndex] = .generated
                        }
                        if let pending = kokoroPendingPlay, pending.generationID == generationID,
                            pending.chunkIndex == chunkIndex
                        {
                            kokoroPendingPlay = nil
                            playChunk(generationID: generationID, chunkIndex: chunkIndex)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Don't let one bad chunk hang its row forever
                        // ("stuck on Generating…") or kill the whole
                        // worker — mark just this chunk failed and move on
                        // to the rest of the queue.
                        kokoroGenerations[genIndex].chunkStates[chunkIndex] = .failed
                        kokoroGenerations[genIndex].error = error.localizedDescription
                        if kokoroPendingPlay?.generationID == generationID {
                            kokoroPendingPlay = nil
                            kokoroGenerations[genIndex].isBuffering = false
                        }
                    }
                }
                status = "Idle"
            } catch is CancellationError {
                // Cleared by a reset (e.g. switching engines) — nothing to report.
            } catch {
                status = "Error: \(error.localizedDescription)"
                isBusy = false
            }
        }
    }

    /// First `.waiting` chunk across all tracks, in creation order.
    private func nextPendingKokoroChunk() -> (generationIndex: Int, chunkIndex: Int)? {
        for (genIndex, generation) in kokoroGenerations.enumerated() {
            if let chunkIndex = generation.chunkStates.firstIndex(of: .waiting) {
                return (genIndex, chunkIndex)
            }
        }
        return nil
    }

    // MARK: - Kokoro: Play (each track is independent — only one plays at a time)

    /// Tapping a track's own play/pause button. Switching to a different
    /// track than the one currently active stops that one and starts this
    /// one from its beginning — like picking a different song, not mixing
    /// them.
    func toggleKokoroPlayback(for generationID: KokoroGeneration.ID) {
        guard let genIndex = kokoroGenerations.firstIndex(where: { $0.id == generationID }) else {
            return
        }
        if kokoroActiveGenerationID == generationID {
            if kokoroGenerations[genIndex].isBuffering {
                return
            } else if kokoroGenerations[genIndex].isPlaying {
                kokoroPlayer?.pause()
                kokoroGenerations[genIndex].isPlaying = false
            } else if kokoroPlayer != nil {
                kokoroPlayer?.play()
                kokoroGenerations[genIndex].isPlaying = true
            } else {
                playChunk(generationID: generationID, chunkIndex: kokoroGenerations[genIndex].currentChunkIndex)
            }
        } else {
            play(generationID: generationID)
        }
    }

    private func play(generationID: KokoroGeneration.ID) {
        guard let genIndex = kokoroGenerations.firstIndex(where: { $0.id == generationID }) else {
            return
        }
        if let activeID = kokoroActiveGenerationID, activeID != generationID,
            let activeIndex = kokoroGenerations.firstIndex(where: { $0.id == activeID })
        {
            kokoroPlayer?.stop()
            kokoroPlayer = nil
            kokoroPlayerDelegate = nil
            kokoroGenerations[activeIndex].isPlaying = false
            kokoroGenerations[activeIndex].isBuffering = false
        }
        kokoroActiveGenerationID = generationID
        kokoroGenerations[genIndex].currentChunkIndex = 0
        playChunk(generationID: generationID, chunkIndex: 0)
    }

    private func playChunk(generationID: KokoroGeneration.ID, chunkIndex: Int) {
        guard let genIndex = kokoroGenerations.firstIndex(where: { $0.id == generationID }) else {
            return
        }
        kokoroActiveGenerationID = generationID
        kokoroGenerations[genIndex].currentChunkIndex = chunkIndex
        // A failed chunk will never be generated by the worker (it only
        // retries .waiting ones) — buffering forever here would hang the
        // row's spinner permanently instead of reflecting the failure.
        guard kokoroGenerations[genIndex].chunkStates[chunkIndex] != .failed else {
            kokoroGenerations[genIndex].isBuffering = false
            return
        }
        guard let data = kokoroGenerations[genIndex].chunkAudio[chunkIndex] else {
            kokoroPendingPlay = (generationID, chunkIndex)
            kokoroGenerations[genIndex].isBuffering = true
            return
        }
        do {
            let player = try AVAudioPlayer(data: data)
            let delegate = KokoroChunkPlaybackDelegate { [weak self] in
                Task { @MainActor in self?.advanceKokoroChunk(generationID: generationID) }
            }
            player.delegate = delegate
            kokoroPlayerDelegate = delegate
            kokoroPlayer = player

            kokoroGenerations[genIndex].chunkStates[chunkIndex] = .playing
            kokoroGenerations[genIndex].isBuffering = false
            kokoroGenerations[genIndex].isPlaying = true
            player.play()
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func advanceKokoroChunk(generationID: KokoroGeneration.ID) {
        guard let genIndex = kokoroGenerations.firstIndex(where: { $0.id == generationID }) else {
            return
        }
        let finishedIndex = kokoroGenerations[genIndex].currentChunkIndex
        if kokoroGenerations[genIndex].chunkStates.indices.contains(finishedIndex) {
            kokoroGenerations[genIndex].chunkStates[finishedIndex] = .generated
        }
        let nextIndex = finishedIndex + 1
        guard nextIndex < kokoroGenerations[genIndex].chunkTexts.count else {
            // End of this track — unlike the old shared-queue design, this
            // does NOT auto-advance into a different generation; each one
            // is independent, like separate songs, and simply stops.
            kokoroGenerations[genIndex].isPlaying = false
            kokoroGenerations[genIndex].isBuffering = false
            kokoroGenerations[genIndex].currentChunkIndex = 0
            kokoroPlayer = nil
            kokoroPlayerDelegate = nil
            return
        }
        playChunk(generationID: generationID, chunkIndex: nextIndex)
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

/// Same bridge as `KokoroChunkPlaybackDelegate`, for the dedicated voice
/// preview player — kept separate so the two AVAudioPlayer instances never
/// share a delegate.
private final class PreviewPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
