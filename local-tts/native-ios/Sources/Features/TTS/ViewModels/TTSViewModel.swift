import AVFoundation
import Combine
import FluidAudio

@MainActor
final class TTSViewModel: ObservableObject {
    // Voice rosters live in `VoiceCatalog` alongside each voice's
    // avatar/tagline/description/preview line — these stay as plain code
    // lists for the call sites that only need names (pickers, counts, the
    // eager per-voice download loop).
    nonisolated static var kokoroVoices: [String] { kokoroVoices(for: .english) }
    nonisolated static var mandarinVoices: [String] { kokoroVoices(for: .mandarin) }
    nonisolated static var japaneseVoices: [String] { kokoroVoices(for: .japanese) }
    nonisolated static var pocketVoices: [String] { VoiceCatalog.pocket.map(\.code) }

    nonisolated static func kokoroVoices(for variant: KokoroVariant) -> [String] {
        VoiceCatalog.voices(for: variant).map(\.code)
    }

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
    // Which Kokoro variant to use — one `KokoroAneManager` per variant (the
    // SDK's chain/vocab differ per variant, same reasoning as
    // `pocketLanguage`). Same stop-in-flight-generation guard.
    @Published var kokoroVariant: KokoroVariant = .english {
        didSet {
            guard oldValue != kokoroVariant else { return }
            stopAllPlayback()
        }
    }
    @Published var pocketVoice = "alba"
    // Which Pocket TTS language pack to use — one `PocketTtsManager` per
    // language (the SDK fixes `language` at init), so changing this
    // switches which manager/service `runPocketTts()` routes to. Same
    // stop-in-flight-generation guard as `kokoroVoice`'s didSet.
    @Published var pocketLanguage: PocketLanguage = .english {
        didSet {
            guard oldValue != pocketLanguage else { return }
            stopAllPlayback()
        }
    }
    // Set by VoiceSettingsSheet's "My Voices" section — when non-nil (and
    // engine == .pocketTts), runPocketTts() synthesizes with this cloned
    // voice's conditioning data instead of the named `pocketVoice` preset.
    // Picking any normal voice clears this back to nil.
    @Published var selectedClonedVoice: ClonedVoice?
    @Published var text = "Hello from FluidAudio!"
    @Published var status = "Idle"
    @Published var isBusy = false
    @Published var initSeconds: TimeInterval?
    @Published var synthSeconds: TimeInterval?
    @Published var isWarmInit = false

    @Published var timeToFirstAudio: TimeInterval?
    @Published var streamChunkProgress: String?
    @Published var isTextSheetPresented = false

    // MARK: - Import screen: voice-pack setup + new sheet flags

    /// Which packs are on disk, where, and any download in flight. Views that
    /// show pack state observe this directly (`viewModel.packs`) — nested
    /// ObservableObject changes don't reach a parent's objectWillChange.
    let packs: VoicePackStore

    // Separate from isTextSheetPresented (the Home tab's own sheet flag) so
    // the two tabs' modals don't fight over one bool.
    @Published var isSetupPresented = false
    @Published var isWriteTextPresented = false
    @Published var isVoiceSettingsPresented = false

    // MARK: - Kokoro: one independent track per "Generate" tap

    // Append-only, like a playlist — each Generate tap adds a new track
    // rather than merging into an existing one, so past generations stay
    // in the list, each with its own play button.
    @Published var kokoroGenerations: [KokoroGeneration] = []
    @Published var kokoroActiveGenerationID: KokoroGeneration.ID?

    private var kokoroModelsReady = false
    private var kokoroPendingPlay: (generationID: KokoroGeneration.ID, chunkIndex: Int)?
    // Fires once, when a given generation finishes every chunk — see
    // generateKokoro's doc comment.
    private var kokoroCompletionHandlers: [KokoroGeneration.ID: ([Data]) -> Void] = [:]
    private var kokoroGenerationTask: Task<Void, Never>?
    private var kokoroPlayer: AVAudioPlayer?
    private var kokoroPlayerDelegate: KokoroChunkPlaybackDelegate?

    // One service per variant, each wrapping that variant's own manager.
    // `kokoroService` below reads whichever one matches the current
    // `kokoroVariant`, so every existing `kokoroService.xxx` call site
    // keeps working unchanged.
    private let kokoroServices: [KokoroVariant: KokoroEngineService]
    private var kokoroService: KokoroEngineService { kokoroServices[kokoroVariant]! }
    // One service per language, each wrapping that language's own
    // manager but sharing the same audio engine/node (only one language
    // ever generates/plays at a time). `pocketService` below reads
    // whichever one matches the current `pocketLanguage`, so every
    // existing `pocketService.xxx` call site keeps working unchanged.
    private let pocketServices: [PocketLanguage: PocketEngineService]
    private var pocketService: PocketEngineService { pocketServices[pocketLanguage]! }
    private var audioPlayer: AVAudioPlayer?

    init(dependencies: DependencyContainer) {
        kokoroServices = Dictionary(
            uniqueKeysWithValues: KokoroVariant.allCases.map { variant in
                let manager: KokoroAneManager
                let directory: URL?
                switch variant {
                case .english:
                    manager = dependencies.kokoroManager
                    directory = dependencies.kokoroModelDirectory
                case .mandarin:
                    manager = dependencies.kokoroMandarinManager
                    directory = nil
                case .japanese:
                    manager = dependencies.kokoroJapaneseManager
                    directory = nil
                }
                return (variant, KokoroEngineService(manager: manager, directory: directory, variant: variant))
            })
        pocketServices = Dictionary(
            uniqueKeysWithValues: PocketLanguage.allCases.map { language in
                (
                    language,
                    PocketEngineService(
                        manager: dependencies.pocketManagers[language]!,
                        audioEngine: dependencies.audioEngine,
                        playerNode: dependencies.playerNode,
                        streamFormat: dependencies.streamFormat)
                )
            })
        packs = VoicePackStore(
            kokoroModelDirectory: dependencies.kokoroModelDirectory,
            isKokoroPackBundled: dependencies.isKokoroPackBundled)
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

    /// For English, only meaningfully does anything if the bundled-copy
    /// step in DependencyContainer failed (isKokoroPackReady(.english)
    /// already false) — the common case is already ready before this could
    /// ever be called. For Mandarin this is the real, and only, download
    /// path — no bundled fallback exists.
    func downloadKokoroPackIfNeeded(variant: KokoroVariant = .english) async {
        guard !packs.isKokoroPackReady(variant) else { return }
        status = "Downloading Kokoro pack (\(variant.displayName))…"
        isBusy = true
        packs.beginDownload(packID: VoicePack.kokoro(variant).id)
        defer {
            isBusy = false
            packs.endDownload()
        }
        do {
            let resolvedDirectory = try await kokoroServices[variant]!.ensureModels(
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.status = self.packs.apply(
                            progress, phaseWeight: 1.0,
                            fetchTotal: { await VoicePackSizeService.kokoroTotalBytes(variant: variant) })
                    }
                })
            packs.noteModelDirectory(resolvedDirectory, for: variant)
            try await kokoroServices[variant]!.initialize()
            packs.markKokoroDownloaded(variant)
            status = "Idle"
        } catch {
            status = "Kokoro pack (\(variant.displayName)) download failed: \(error.localizedDescription)"
        }
    }

    /// PocketTTS has no bundled fallback, so each language is a real
    /// ~527MB network download the user opts into from the Setup sheet.
    /// On success, that language's "already downloaded" flag is persisted
    /// — there's no cheap on-disk check to ask the SDK instead (see
    /// isPocketPackDownloaded's comment). Defaults to English so any
    /// caller that predates multi-language support keeps working as-is.
    func downloadPocketPackIfNeeded(language: PocketLanguage = .english) async {
        guard !packs.isPocketPackDownloaded(language) else { return }
        status = "Downloading Pocket TTS pack (\(language.displayName))…"
        isBusy = true
        packs.beginDownload(packID: VoicePack.pocket(language).id)
        defer {
            isBusy = false
            packs.endDownload()
        }
        do {
            try await pocketServices[language]!.ensureModels(progressHandler: { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.status = self.packs.apply(
                        progress, phaseWeight: 1.0,
                        fetchTotal: { await VoicePackSizeService.pocketTotalBytes(language: language) })
                }
            })
            try await pocketServices[language]!.initialize()
            packs.markPocketDownloaded(language)
            status = "Idle"
        } catch {
            status = "Pocket TTS pack (\(language.displayName)) download failed: \(error.localizedDescription)"
        }
    }

    private func resetRunState() {
        stopAllPlayback()
        isBusy = true
        packs.resetProgress()
        initSeconds = nil
        synthSeconds = nil
        timeToFirstAudio = nil
        streamChunkProgress = nil
    }

    private func stopAllPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        // Stop every language's service, not just the current
        // `pocketLanguage` — this can run from that same property's
        // didSet, which fires *after* the value already changed, so
        // reading the (now computed-current) `pocketService` here would
        // stop the new language's idle service instead of the old one
        // that's actually still streaming. Only one is ever really
        // active, so stopping all of them is harmless and avoids the
        // ordering problem entirely.
        for service in pocketServices.values { service.stopPlayback() }

        kokoroGenerationTask?.cancel()
        kokoroGenerationTask = nil
        kokoroPlayer?.stop()
        kokoroPlayer = nil
        kokoroPlayerDelegate = nil
        kokoroGenerations = []
        kokoroActiveGenerationID = nil
        kokoroModelsReady = false
        kokoroPendingPlay = nil
        kokoroCompletionHandlers = [:]
    }

    // MARK: - Kokoro: Generate (always creates a new, independent track)

    /// Chunks the current text into a new `KokoroGeneration` (its own
    /// track, like a new song in a playlist — never merged into an
    /// existing one) and appends it to the list, then makes sure the
    /// background worker is running to fill in its audio. Returns the new
    /// track's id, or nil if the text was empty.
    ///
    /// `onFullyGenerated`, if given, fires exactly once — with every
    /// chunk's audio, in order — the moment this specific track finishes
    /// generating (not when the whole worker queue drains, since other
    /// tracks may still be pending). Never fires if any chunk fails, since
    /// an incomplete recording isn't worth persisting. Callers use this to
    /// persist the audio for Library playback (see LibraryViewModel.attachAudio) —
    /// TTSViewModel itself has no idea Library exists, it just reports
    /// completion.
    @discardableResult
    func generateKokoro(onFullyGenerated: (([Data]) -> Void)? = nil) -> KokoroGeneration.ID? {
        let chunks = KokoroTextChunker.chunk(text)
        guard !chunks.isEmpty else { return nil }

        let generation = KokoroGeneration(
            text: text,
            chunkTexts: chunks,
            chunkAudio: Array(repeating: nil, count: chunks.count),
            chunkStates: Array(repeating: .waiting, count: chunks.count))
        kokoroGenerations.append(generation)
        if let onFullyGenerated {
            kokoroCompletionHandlers[generation.id] = onFullyGenerated
        }

        ensureKokoroGenerationRunning()
        return generation.id
    }

    /// Re-synthesizes a saved Library entry and starts playing it — used
    /// when no saved audio exists yet to replay instead (see
    /// `playPersistedAudio` for the normal, no-regeneration path). Same
    /// `onFullyGenerated` contract as `generateKokoro` — pass it to
    /// backfill the saved audio so the next open plays straight from disk.
    /// Kokoro only — callers should gate on `SavedGeneration.engine == .kokoroAne`.
    @discardableResult
    func playFromSavedGeneration(
        text savedText: String, voice savedVoice: String, onFullyGenerated: (([Data]) -> Void)? = nil
    ) -> KokoroGeneration.ID? {
        text = savedText
        if kokoroVoice != savedVoice {
            kokoroVoice = savedVoice
        }
        guard let newID = generateKokoro(onFullyGenerated: onFullyGenerated) else { return nil }
        toggleKokoroPlayback(for: newID)
        return newID
    }

    /// Plays already-saved audio straight from disk — no synthesis at all.
    /// Recomputes the same chunk boundaries `KokoroTextChunker` would have
    /// produced originally (deterministic, given the same text) so the
    /// reconstructed track's `chunkTexts` line up with the loaded
    /// `chunkAudio`, and read-along highlighting behaves identically to a
    /// live generation. Returns nil (caller should fall back to
    /// `playFromSavedGeneration`) if the counts don't match — e.g. the
    /// chunker's behavior changed since this was saved.
    @discardableResult
    func playPersistedAudio(text savedText: String, chunkAudio: [Data]) -> KokoroGeneration.ID? {
        let chunks = KokoroTextChunker.chunk(savedText)
        guard chunks.count == chunkAudio.count, !chunks.isEmpty else { return nil }

        let generation = KokoroGeneration(
            text: savedText,
            chunkTexts: chunks,
            chunkAudio: chunkAudio.map(Optional.init),
            chunkStates: Array(repeating: .generated, count: chunks.count))
        kokoroGenerations.append(generation)
        toggleKokoroPlayback(for: generation.id)
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
                    let variant = kokoroVariant
                    let resolvedDirectory = try await kokoroService.ensureModels(progressHandler: { progress in
                        Task { @MainActor in
                            self.status = self.packs.apply(
                                progress, phaseWeight: 0.5,
                                fetchTotal: { await VoicePackSizeService.kokoroTotalBytes(variant: variant) })
                        }
                    })
                    packs.noteModelDirectory(resolvedDirectory, for: variant)
                    isWarmInit = !packs.didDownload

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
                        notifyIfFullyGenerated(generationID: generationID, genIndex: genIndex)
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
                        // A failed chunk still ends this generation's
                        // waiting period — drop its completion handler
                        // (without calling it) so it doesn't fire later
                        // for an incomplete recording.
                        notifyIfFullyGenerated(generationID: generationID, genIndex: genIndex)
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

    /// Fires (and removes) `generationID`'s completion handler, if any,
    /// once every chunk has settled — but only on a clean run: any
    /// `.failed` chunk means the recording is incomplete, so the handler
    /// is dropped without being called (nothing worth persisting).
    private func notifyIfFullyGenerated(generationID: KokoroGeneration.ID, genIndex: Int) {
        guard kokoroGenerations[genIndex].isFullyGenerated,
            let handler = kokoroCompletionHandlers.removeValue(forKey: generationID)
        else { return }
        guard !kokoroGenerations[genIndex].chunkStates.contains(.failed) else { return }
        let chunkAudio = kokoroGenerations[genIndex].chunkAudio.compactMap { $0 }
        guard chunkAudio.count == kokoroGenerations[genIndex].chunkAudio.count else { return }
        handler(chunkAudio)
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
        let clonedVoice = selectedClonedVoice
        let inputText = text
        // Snapshot which language's service this run uses at the moment
        // Generate is tapped — pocketLanguage changing mid-run already
        // triggers stopAllPlayback() via its own didSet, but pinning the
        // local reference too keeps this whole closure self-consistent
        // regardless of timing (a cloned voice's own language is set on
        // `pocketLanguage` at selection time in VoiceSettingsSheet, so this
        // is correct for cloned voices as well as named presets).
        let pocketService = pocketServices[pocketLanguage]!
        let language = pocketLanguage

        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                status = "Checking cache…"
                let initStart = Date()
                try await pocketService.ensureModels(progressHandler: { progress in
                    Task { @MainActor in
                        self.status = self.packs.apply(
                            progress, phaseWeight: 1.0,
                            fetchTotal: { await VoicePackSizeService.pocketTotalBytes(language: language) })
                    }
                })
                isWarmInit = !packs.didDownload

                status = "Loading models…"
                try await pocketService.initialize()
                initSeconds = Date().timeIntervalSince(initStart)

                status = "Synthesizing (streaming)…"
                try pocketService.preparePlayback()

                let synthStart = Date()
                let stream: AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error>
                if let clonedVoice {
                    let voiceData = try pocketService.loadClonedVoice(from: clonedVoice.fileURL)
                    stream = try await pocketService.synthesizeStreaming(text: inputText, voiceData: voiceData)
                } else {
                    stream = try await pocketService.synthesizeStreaming(text: inputText, voice: voice)
                }
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

