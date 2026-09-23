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
    // Changing voice mid-session would otherwise leave stale playback
    // running under the old voice. `kokoroModelsReady` is reset here too
    // (not just in stopEnginePlayback, which other engines' didSets also
    // call) — a new voice genuinely needs its own pack preloaded.
    @Published var kokoroVoice = "af_heart" {
        didSet {
            guard oldValue != kokoroVoice else { return }
            stopEnginePlayback()
            kokoroModelsReady = false
        }
    }
    // Which Kokoro variant to use — one `KokoroAneManager` per variant (the
    // SDK's chain/vocab differ per variant, same reasoning as
    // `pocketLanguage`). Same stop-in-flight-playback guard.
    @Published var kokoroVariant: KokoroVariant = .english {
        didSet {
            guard oldValue != kokoroVariant else { return }
            stopEnginePlayback()
            kokoroModelsReady = false
        }
    }
    @Published var pocketVoice = "alba"
    // Which Pocket TTS language pack to use — one `PocketTtsManager` per
    // language (the SDK fixes `language` at init), so changing this
    // switches which manager/service `runPocketTts()` routes to. Same
    // stop-in-flight-playback guard as `kokoroVoice`'s didSet.
    @Published var pocketLanguage: PocketLanguage = .english {
        didSet {
            guard oldValue != pocketLanguage else { return }
            stopEnginePlayback()
        }
    }
    // Independent of each other, unlike Kokoro's variant (= language) or
    // Pocket's language (= manager) — the same voice speaks any language,
    // chosen separately. Same stop-in-flight-playback guard as the others.
    @Published var supertonicLanguage: SupertonicLanguage = .default {
        didSet {
            guard oldValue != supertonicLanguage else { return }
            stopEnginePlayback()
        }
    }
    @Published var supertonicVoice: SupertonicVoice = .default {
        didSet {
            guard oldValue != supertonicVoice else { return }
            stopEnginePlayback()
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
    @Published private(set) var isReaderPlaybackActive = false
    @Published var initSeconds: TimeInterval?
    @Published var synthSeconds: TimeInterval?
    @Published var isWarmInit = false

    @Published var timeToFirstAudio: TimeInterval?
    @Published var streamChunkProgress: String?

    // MARK: - Cold-start notice (issue #4)

    /// True while an engine is doing its one-time `ensureModels()` +
    /// `initialize()` for a model the user hasn't seen prepared yet this
    /// session — drives WriteTextView's "Initializing model…" notice.
    @Published private(set) var isPreparingModel = false

    // Which models we've already shown that notice for, keyed by
    // variant/language so English -> Mandarin (a genuinely different model,
    // a real cold load) shows it again while switching voices *within* a
    // variant doesn't. Deliberately separate from `kokoroModelsReady`
    // below, which `kokoroVoice`/`kokoroVariant`'s own didSet clears on
    // every change — that re-init is warm and fast, and shouldn't
    // re-announce itself.
    private var noticedKokoroVariants: Set<KokoroVariant> = []
    private var noticedPocketLanguages: Set<PocketLanguage> = []
    private var noticedSupertonic3 = false
    private var readerPlaybackTask: Task<Void, Never>?
    private var readerPlaybackID: UUID?

    // MARK: - Import screen: voice-pack setup + new sheet flags

    /// Which packs are on disk, where, and any download in flight. Views that
    /// show pack state observe this directly (`viewModel.packs`) — nested
    /// ObservableObject changes don't reach a parent's objectWillChange.
    let packs: VoicePackStore

    @Published var isWriteTextPresented = false
    @Published var isVoiceSettingsPresented = false

    // MARK: - Kokoro

    private var kokoroModelsReady = false
    // Set while prepareKokoroModelIfNeeded() is warming the model ahead of
    // a per-chapter Generate; ChapterSynthesisService's own ensureReady
    // dedup handles concurrent-init safety for chapters, but this still
    // guards prepareKokoroModelIfNeeded against running twice itself.
    private var kokoroWarmUpTask: Task<Void, Never>?

    // One service per variant, each wrapping that variant's own manager.
    // `kokoroService` below reads whichever one matches the current
    // `kokoroVariant`. Exposed (not `private`) so ChapterSynthesisService
    // can be constructed from the same instances — see KokoroAneTestApp.
    let kokoroServices: [KokoroVariant: KokoroEngineService]
    private var kokoroService: KokoroEngineService { kokoroServices[kokoroVariant]! }
    // One service per language, each wrapping that language's own
    // manager but sharing the same audio engine/node (only one language
    // ever generates/plays at a time). `pocketService` below reads
    // whichever one matches the current `pocketLanguage`, so every
    // existing `pocketService.xxx` call site keeps working unchanged.
    private let pocketServices: [PocketLanguage: PocketEngineService]
    private var pocketService: PocketEngineService { pocketServices[pocketLanguage]! }

    // A single service, unlike the per-variant/per-language dictionaries
    // above — see DependencyContainer.supertonic3Manager's doc comment.
    private let supertonicService: Supertonic3EngineService
    private var supertonicPlayer: AVAudioPlayer?
    private var supertonicPlayerDelegate: AudioPlaybackDelegate?

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
        supertonicService = Supertonic3EngineService(
            manager: dependencies.supertonic3Manager, directory: nil,
            vectorEstimator: DependencyContainer.supertonic3VectorEstimator)
        packs = VoicePackStore(
            kokoroModelDirectory: dependencies.kokoroModelDirectory,
            isKokoroPackBundled: dependencies.isKokoroPackBundled)
    }

    /// Plays a saved reader page with the engine and voice captured when the
    /// project was created, rather than whichever engine is selected now.
    func speakPage(
        text: String, engine pageEngine: Engine, voiceName: String,
        clonedVoice: ClonedVoice? = nil
    ) {
        engine = pageEngine
        switch pageEngine {
        case .kokoroAne:
            break
        case .pocketTts:
            if let clonedVoice {
                selectedClonedVoice = clonedVoice
                pocketLanguage = clonedVoice.language
            } else {
                selectedClonedVoice = nil
                pocketVoice = voiceName
            }
            runPocketTts(text: text)
            isReaderPlaybackActive = true
        case .supertonic3:
            if let voice = SupertonicVoice.allCases.first(where: {
                $0.rawValue == voiceName || $0.displayName == voiceName
            }) {
                supertonicVoice = voice
            }
            runSupertonicTts(text: text)
            isReaderPlaybackActive = true
        }
    }

    /// Hides the "Initializing model…" notice early. Preparation itself
    /// keeps running — this only dismisses the message.
    func dismissModelPreparingNotice() {
        isPreparingModel = false
    }

    /// Starts Kokoro's one-time load as soon as Write Text opens, so the
    /// model is usually warm by the time the user has finished typing and
    /// taps Generate — rather than making them wait for it afterwards.
    ///
    /// Only warms the *selected* engine's model: Kokoro is the default, but
    /// warming it for someone who's switched to Pocket/Supertonic-3 would
    /// load the wrong one and pay the cost twice.
    func prepareKokoroModelIfNeeded() {
        guard engine == .kokoroAne, !kokoroModelsReady, kokoroWarmUpTask == nil else { return }

        let variant = kokoroVariant
        let voice = kokoroVoice
        let service = kokoroService
        isPreparingModel = !noticedKokoroVariants.contains(variant)

        kokoroWarmUpTask = Task { [weak self] in
            guard let self else { return }
            defer { self.kokoroWarmUpTask = nil }
            do {
                let resolvedDirectory = try await service.ensureModels(progressHandler: nil)
                packs.noteModelDirectory(resolvedDirectory, for: variant)
                try await service.initialize(preloadVoice: voice)
                // Only claim readiness if this is still the selected
                // variant — the user may have switched mid-warm-up, in
                // which case the newly-selected model genuinely isn't
                // loaded and Generate must still do its own init.
                if kokoroVariant == variant { kokoroModelsReady = true }
                noticedKokoroVariants.insert(variant)
                // Last, and deliberately after readiness is recorded:
                // loading the models still leaves CoreML's first-inference
                // ANE specialization unpaid, which is most of what made the
                // first Generate slow. If this throws, the models are
                // loaded regardless — Generate just pays the compile.
                try await service.warmUpInference(voice: voice)
            } catch {
                // Best-effort: Generate runs the same calls itself and
                // surfaces any real failure there, with its own error text.
            }
            isPreparingModel = false
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

    /// Unlike the other two, there's exactly one Supertonic-3 pack — no
    /// per-variant/per-language argument (see `VoicePack.supertonic3`).
    func downloadSupertonic3PackIfNeeded() async {
        guard !packs.isSupertonic3Downloaded else { return }
        status = "Downloading Supertonic-3 pack…"
        isBusy = true
        packs.beginDownload(packID: VoicePack.supertonic3.id)
        defer {
            isBusy = false
            packs.endDownload()
        }
        do {
            let resolvedDirectory = try await supertonicService.ensureModels(progressHandler: {
                [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.status = self.packs.apply(
                        progress, phaseWeight: 1.0,
                        fetchTotal: { await VoicePackSizeService.supertonic3TotalBytes() })
                }
            })
            packs.noteSupertonic3ModelDirectory(resolvedDirectory)
            try await supertonicService.initialize()
            packs.markSupertonic3Downloaded()
            status = "Idle"
        } catch {
            status = "Supertonic-3 pack download failed: \(error.localizedDescription)"
        }
    }

    private func resetRunState() {
        stopEnginePlayback()
        isBusy = true
        packs.resetProgress()
        initSeconds = nil
        synthSeconds = nil
        timeToFirstAudio = nil
        streamChunkProgress = nil
    }

    // Stops Pocket/Supertonic-3 playback and cancels the active reader task.
    // Kokoro page playback lives entirely on `ChapterAudioPlayer`; app-level
    // background Generate jobs are intentionally unaffected.
    func stopEnginePlayback() {
        readerPlaybackTask?.cancel()
        readerPlaybackTask = nil
        readerPlaybackID = nil
        isReaderPlaybackActive = false
        supertonicPlayer?.stop()
        supertonicPlayer = nil
        supertonicPlayerDelegate = nil
        // Stop every language's service, not just the current
        // `pocketLanguage` — this can run from that same property's
        // didSet, which fires *after* the value already changed, so
        // reading the (now computed-current) `pocketService` here would
        // stop the new language's idle service instead of the old one
        // that's actually still streaming. Only one is ever really
        // active, so stopping all of them is harmless and avoids the
        // ordering problem entirely.
        for service in pocketServices.values { service.stopPlayback() }
    }

    // `text` defaults to the ViewModel's editor value; the page reader passes
    // the selected page explicitly.
    private func runPocketTts(text overrideText: String? = nil) {
        resetRunState()
        let voice = pocketVoice
        let clonedVoice = selectedClonedVoice
        let inputText = overrideText ?? text
        // Snapshot which language's service this run uses at the moment
        // Generate is tapped — pocketLanguage changing mid-run already
        // triggers stopEnginePlayback() via its own didSet, but pinning the
        // local reference too keeps this whole closure self-consistent
        // regardless of timing (a cloned voice's own language is set on
        // `pocketLanguage` at selection time in VoiceSettingsSheet, so this
        // is correct for cloned voices as well as named presets).
        let pocketService = pocketServices[pocketLanguage]!
        let language = pocketLanguage

        let playbackID = UUID()
        readerPlaybackID = playbackID
        readerPlaybackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                status = "Checking cache…"
                let initStart = Date()
                isPreparingModel = !noticedPocketLanguages.contains(language)
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
                noticedPocketLanguages.insert(language)
                isPreparingModel = false

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
                    try Task.checkCancellation()
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
            } catch is CancellationError {
                status = "Idle"
            } catch {
                status = "Error: \(error.localizedDescription)"
                if readerPlaybackID == playbackID {
                    isReaderPlaybackActive = false
                }
            }
            isBusy = false
            // The notice has no
            // auto-dismiss, so every exit path has to clear it.
            isPreparingModel = false
            if readerPlaybackID == playbackID {
                readerPlaybackTask = nil
            }
        }
    }

    /// Single-shot generate-then-play, closer to `runPocketTts()`'s overall
    /// shape than Kokoro's persistent-worker pattern: Supertonic-3 has no
    /// background queue, one call returns one complete clip. Unlike Kokoro,
    /// text isn't pre-chunked here — the SDK chunks internally and the app
    /// has no visibility into where, so there's no per-chunk read-along for
    /// this engine; it plays back as one track, same UX tier as Pocket.
    private func runSupertonicTts(text overrideText: String? = nil) {
        resetRunState()
        let inputText = overrideText ?? text
        let language = supertonicLanguage
        let voice = supertonicVoice

        let playbackID = UUID()
        readerPlaybackID = playbackID
        readerPlaybackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                status = "Checking cache…"
                let initStart = Date()
                isPreparingModel = !noticedSupertonic3
                let resolvedDirectory = try await supertonicService.ensureModels(progressHandler: {
                    [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.status = self.packs.apply(
                            progress, phaseWeight: 1.0,
                            fetchTotal: { await VoicePackSizeService.supertonic3TotalBytes() })
                    }
                })
                packs.noteSupertonic3ModelDirectory(resolvedDirectory)
                isWarmInit = !packs.didDownload

                status = "Loading models…"
                try await supertonicService.initialize()
                initSeconds = Date().timeIntervalSince(initStart)
                noticedSupertonic3 = true
                isPreparingModel = false

                status = "Synthesizing…"
                let synthStart = Date()
                let data = try await supertonicService.synthesize(
                    text: inputText, language: language.code, voice: voice)
                try Task.checkCancellation()
                synthSeconds = Date().timeIntervalSince(synthStart)

                let player = try AVAudioPlayer(data: data)
                let delegate = AudioPlaybackDelegate { [weak self] in
                    Task { @MainActor in
                        guard self?.readerPlaybackID == playbackID else { return }
                        self?.supertonicPlayer = nil
                        self?.supertonicPlayerDelegate = nil
                        self?.isReaderPlaybackActive = false
                        self?.readerPlaybackTask = nil
                        self?.readerPlaybackID = nil
                    }
                }
                player.delegate = delegate
                supertonicPlayerDelegate = delegate
                supertonicPlayer = player
                player.play()

                status = "Idle"
            } catch is CancellationError {
                status = "Idle"
            } catch {
                status = "Error: \(error.localizedDescription)"
                if readerPlaybackID == playbackID {
                    isReaderPlaybackActive = false
                }
            }
            isBusy = false
            // The notice has no
            // auto-dismiss, so every exit path has to clear it.
            isPreparingModel = false
            if readerPlaybackID == playbackID, supertonicPlayer == nil {
                readerPlaybackTask = nil
            }
        }
    }
}
