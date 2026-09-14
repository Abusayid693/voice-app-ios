import AVFoundation
import Combine
import FluidAudio

@MainActor
final class TTSViewModel: ObservableObject {
    // All 28 standard Kokoro-82M English voices. FluidAudio's own hosted
    // ANE repo only publishes af_heart (a real model-conversion
    // constraint, not just a missing download — see
    // docs/adr/0002-custom-kokoro-model-bundle.md), but
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

    // 2 voices from FluidAudio's own hosted numbered set (zf_001 — the
    // documented default — and zm_009, the lowest-numbered male voice
    // available there; zm_001 doesn't exist, confirmed via a direct HTTP
    // check) plus the 8 voices hexgrad/Kokoro-82M itself names and grades
    // in VOICES.md. The other 98 numbered voices FluidAudio hosts
    // (zf_002...zf_099, zm_010...zm_100) are deliberately excluded — their
    // provenance traces to an undocumented third-party project
    // (ardorleo/kokoro-tts-zh), not to hexgrad, so there's no way to
    // confirm they're genuinely distinct speakers. The 8 named voices
    // below are bundled in the app (BundledMandarinVoices/, converted from
    // hexgrad's own .pt tensors — see model-conversion/kokoro-mandarin-voices/)
    // since FluidAudio's repo doesn't host them; KokoroEngineService copies
    // them into place. All graded "D" overall / thin training data per
    // hexgrad's own VOICES.md — the tradeoff for using documented,
    // named voices instead of unverified numbered ones.
    static let mandarinVoices = [
        "zf_001", "zm_009",
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
        "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ]

    // FluidAudio's own official roster (KokoroAneConstants.japaneseVoices,
    // as of the pinned commit — see project.yml) — unlike Mandarin's
    // numbered set, this one has no provenance ambiguity: it's the SDK's
    // own curated list, all 5 confirmed present as real voice .bin files
    // on FluidAudio's hosted repo. No bundling step needed.
    static let japaneseVoices = ["jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo"]

    static func kokoroVoices(for variant: KokoroVariant) -> [String] {
        switch variant {
        case .english: return kokoroVoices
        case .mandarin: return mandarinVoices
        case .japanese: return japaneseVoices
        }
    }

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
    // Which Setup pack (VoicePack.id) is currently downloading, if any —
    // `isBusy` above is shared across the whole ViewModel (generation,
    // every pack download), so gating SetupSheet's per-row spinner on it
    // alone made every not-yet-downloaded row spin at once the moment any
    // one pack started downloading. This tracks the *specific* row.
    @Published private(set) var downloadingPackID: String?
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

    // English is ready as soon as the bundled CustomKokoroModel/ copy
    // succeeds (see DependencyContainer) — for virtually every install
    // that's already true the instant TTSViewModel exists. Mandarin has no
    // bundled fallback, so it's persisted the same way
    // pocketPackDownloadedLanguages is, below.
    @Published private(set) var kokoroDownloadedVariants: Set<KokoroVariant> = []
    // Unlike Kokoro, PocketTTS has no bundled fallback — each language is a
    // real ~527MB network download the user must opt into via Setup.
    // Persisted per-language so a relaunch doesn't forget what's already
    // downloaded (the SDK has no cheap, side-effect-free "is this on disk"
    // check to ask instead — see downloadPocketPackIfNeeded()).
    @Published private(set) var pocketPackDownloadedLanguages: Set<PocketLanguage> = []
    // Where the bundled Kokoro pack actually lives on disk (nil if the
    // bundled-copy step failed) — exposed for the Settings > Voice
    // Packs/Storage pages, which report real on-disk sizes rather than
    // estimates.
    let kokoroModelDirectory: URL?
    // Where the Mandarin pack actually landed on disk — unlike English,
    // this isn't known upfront (no bundled directory to point at), so it's
    // only populated once `downloadKokoroPackIfNeeded(variant: .mandarin)`
    // actually resolves it (cheap even when already downloaded — see that
    // function). Deliberately not persisted across relaunches: FluidAudio's
    // own default-cache-directory logic is private, so this app can't
    // recompute the exact path without calling back into the SDK; Settings
    // shows this pack's size as unknown until the user revisits Setup or
    // Write with Mandarin selected at least once per launch. Same class of
    // known imprecision ADR 7 already documents for Pocket TTS's storage
    // reporting, not a new gap this feature introduces.
    @Published private(set) var kokoroMandarinModelDirectory: URL?

    // Separate from isTextSheetPresented (the Home tab's own sheet flag) so
    // the two tabs' modals don't fight over one bool.
    @Published var isSetupPresented = false
    @Published var isWriteTextPresented = false
    @Published var isVoiceSettingsPresented = false

    private static let pocketPackDownloadedLanguagesDefaultsKey = "pocketPackDownloadedLanguages"
    // Original single-language flag, kept only to migrate existing
    // installs — a user who already downloaded Pocket's English pack
    // shouldn't need to re-download it after this key is replaced.
    private static let legacyPocketPackDownloadedBoolKey = "pocketPackDownloaded"
    private static let kokoroDownloadedVariantsDefaultsKey = "kokoroDownloadedVariants"

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
        kokoroDownloadedVariants = Self.loadKokoroDownloadedVariants(bundledEnglish: dependencies.isKokoroPackBundled)
        pocketPackDownloadedLanguages = Self.loadPocketPackDownloadedLanguages()
        kokoroModelDirectory = dependencies.kokoroModelDirectory
    }

    private static func loadKokoroDownloadedVariants(bundledEnglish: Bool) -> Set<KokoroVariant> {
        let defaults = UserDefaults.standard
        var variants: Set<KokoroVariant> = []
        if let rawValues = defaults.array(forKey: kokoroDownloadedVariantsDefaultsKey) as? [String] {
            variants = Set(rawValues.compactMap(KokoroVariant.init(rawValue:)))
        }
        // English doesn't rely on persistence at all — it's ready the
        // instant the bundled copy succeeds, every launch.
        if bundledEnglish { variants.insert(.english) }
        return variants
    }

    private func saveKokoroDownloadedVariants() {
        UserDefaults.standard.set(
            kokoroDownloadedVariants.map(\.rawValue), forKey: Self.kokoroDownloadedVariantsDefaultsKey)
    }

    /// True if the given Kokoro variant is ready to generate with — either
    /// bundled (English) or already downloaded (Mandarin).
    func isKokoroPackReady(_ variant: KokoroVariant) -> Bool {
        kokoroDownloadedVariants.contains(variant)
    }

    /// Convenience for call sites that predate multi-variant support and
    /// only ever meant "the original bundled English pack" — kept so they
    /// don't need to be rewritten for variant-awareness they don't need.
    var isKokoroPackReady: Bool { isKokoroPackReady(.english) }

    private static func loadPocketPackDownloadedLanguages() -> Set<PocketLanguage> {
        let defaults = UserDefaults.standard
        if let rawValues = defaults.array(forKey: pocketPackDownloadedLanguagesDefaultsKey) as? [String] {
            return Set(rawValues.compactMap(PocketLanguage.init(rawValue:)))
        }
        // Pre-multi-language installs only ever had English — migrate the
        // old bool so those users don't lose an already-downloaded pack.
        return defaults.bool(forKey: legacyPocketPackDownloadedBoolKey) ? [.english] : []
    }

    private func savePocketPackDownloadedLanguages() {
        UserDefaults.standard.set(
            pocketPackDownloadedLanguages.map(\.rawValue),
            forKey: Self.pocketPackDownloadedLanguagesDefaultsKey)
    }

    /// True if the given language's Pocket pack has already been
    /// downloaded. Most of the app only ever cares about English (Settings'
    /// Voice Packs/Storage pages, Import's Trending-voices availability) —
    /// `isPocketPackDownloaded` below covers those unchanged.
    func isPocketPackDownloaded(_ language: PocketLanguage) -> Bool {
        pocketPackDownloadedLanguages.contains(language)
    }

    /// Convenience for call sites that predate multi-language support and
    /// only ever meant "the original English pack" — kept so they don't
    /// need to be rewritten for language-awareness they don't need.
    var isPocketPackDownloaded: Bool { isPocketPackDownloaded(.english) }

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

    /// For English, only meaningfully does anything if the bundled-copy
    /// step in DependencyContainer failed (isKokoroPackReady(.english)
    /// already false) — the common case is already ready before this could
    /// ever be called. For Mandarin this is the real, and only, download
    /// path — no bundled fallback exists.
    func downloadKokoroPackIfNeeded(variant: KokoroVariant = .english) async {
        guard !isKokoroPackReady(variant) else { return }
        status = "Downloading Kokoro pack (\(variant.displayName))…"
        isBusy = true
        downloadingPackID = VoicePack.kokoro(variant).id
        defer {
            isBusy = false
            downloadingPackID = nil
        }
        do {
            let resolvedDirectory = try await kokoroServices[variant]!.ensureModels(
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.applyDownloadProgress(
                            progress, phaseWeight: 1.0,
                            fetchTotal: { await self.fetchKokoroTotalBytes(variant: variant) })
                    }
                })
            if variant == .mandarin {
                kokoroMandarinModelDirectory = resolvedDirectory
            }
            try await kokoroServices[variant]!.initialize()
            kokoroDownloadedVariants.insert(variant)
            saveKokoroDownloadedVariants()
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
        guard !isPocketPackDownloaded(language) else { return }
        status = "Downloading Pocket TTS pack (\(language.displayName))…"
        isBusy = true
        downloadingPackID = VoicePack.pocket(language).id
        defer {
            isBusy = false
            downloadingPackID = nil
        }
        do {
            try await pocketServices[language]!.ensureModels(progressHandler: { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyDownloadProgress(
                        progress, phaseWeight: 1.0,
                        fetchTotal: { await self.fetchPocketTtsTotalBytes(language: language) })
                }
            })
            try await pocketServices[language]!.initialize()
            pocketPackDownloadedLanguages.insert(language)
            savePocketPackDownloadedLanguages()
            status = "Idle"
        } catch {
            status = "Pocket TTS pack (\(language.displayName)) download failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Import screen: voice preview playback

    /// Resolves a voice's bundled preview clip, if one exists — shared by
    /// `togglePreview` (actual playback) and `hasPreviewClip` (UI-only
    /// availability check, e.g. to dim a play button before the user taps
    /// it rather than after).
    private static func previewClipURL(voiceName: String, engine: Engine) -> URL? {
        let subdirectory = "VoicePreviews/\(engine == .kokoroAne ? "Kokoro" : "Pocket")"
        return Bundle.main.url(forResource: voiceName, withExtension: "wav", subdirectory: subdirectory)
    }

    /// True if this voice has a bundled preview clip — independent of
    /// whether its pack has been *downloaded* (`isKokoroPackReady`/
    /// `isPocketPackDownloaded`), since preview playback is pure bundled
    /// file playback and never touches the engine at all. Voices without a
    /// pack downloaded yet can still preview fine; voices without a
    /// recorded clip yet (currently: all of Pocket TTS — see
    /// docs/adr/0009-bundled-voice-preview-clips.md) can't preview even if
    /// their pack is downloaded.
    func hasPreviewClip(voiceName: String, engine: Engine) -> Bool {
        Self.previewClipURL(voiceName: voiceName, engine: engine) != nil
    }

    /// Plays (or stops, if already playing) a voice's bundled preview clip
    /// — pure file playback, no synthesis, so this never touches
    /// kokoroService/pocketService and can't collide with an in-progress
    /// "Write text" generation. No-ops if the clip isn't bundled yet (e.g.
    /// Pocket voices before their pass — see
    /// docs/adr/0009-bundled-voice-preview-clips.md).
    func togglePreview(voiceName: String, engine: Engine) {
        let wasPlayingThisVoice = previewingVoiceID == voiceName
        stopPreview()
        guard !wasPlayingThisVoice else { return }

        guard let url = Self.previewClipURL(voiceName: voiceName, engine: engine) else { return }

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
                            self.applyDownloadProgress(
                                progress, phaseWeight: 0.5,
                                fetchTotal: { await self.fetchKokoroTotalBytes(variant: variant) })
                        }
                    })
                    if variant == .mandarin {
                        kokoroMandarinModelDirectory = resolvedDirectory
                    }
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
                        self.applyDownloadProgress(
                            progress, phaseWeight: 1.0,
                            fetchTotal: { await self.fetchPocketTtsTotalBytes(language: language) })
                    }
                })
                isWarmInit = !didDownload

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

    /// Sums file sizes from HuggingFace's public tree API for a Kokoro-ANE
    /// variant's bundle (`FluidInference/kokoro-82m-coreml/ANE` for English,
    /// `ANE-zh` for Mandarin, `ANE-ja` for Japanese) — the SDK's own
    /// progress callback reports a fraction, not byte totals, so this is a
    /// best-effort, independent lookup purely for the "total size"
    /// display. For Mandarin this slightly overcounts (it includes
    /// FluidAudio's full 100-voice `voices/` folder, but `mandarinVoices`
    /// only fetches 2 of those); for Japanese it overcounts more
    /// substantially (includes the ~114MB `assets/` G2P folder, which
    /// fetches lazily on first synthesis, not as part of `ensureModels`)
    /// — acceptable for a progress display, not worth a second, per-file
    /// HF lookup.
    private func fetchKokoroTotalBytes(variant: KokoroVariant) async -> Int64? {
        let subdirectory: String
        switch variant {
        case .english: subdirectory = "ANE"
        case .mandarin: subdirectory = "ANE-zh"
        case .japanese: subdirectory = "ANE-ja"
        }
        return await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url:
                "https://huggingface.co/api/models/FluidInference/kokoro-82m-coreml/tree/main/\(subdirectory)?recursive=true",
            matching: { _ in true })
    }

    /// Same idea, for PocketTTS's English v2.1 pack — but that directory also
    /// holds the GPU-placement/int8 variants, the MLState package, and the
    /// uncompiled `.mlpackage` sources, none of which `ensureModels(placement:
    /// .ane)` actually downloads. Filtering to just the components that call
    /// fetches keeps the total honest.
    private func fetchPocketTtsTotalBytes(language: PocketLanguage) async -> Int64? {
        // `sdkLanguage.rawValue` matches the real v2.1/<name>/ folder name
        // exactly for every case here (english/german/italian/portuguese/
        // spanish) — verified directly against the HuggingFace repo
        // listing, not assumed. All five came back byte-identical in size
        // (~527MB) when this same filter was checked per-language — see
        // docs/adr/0011-pocket-tts-language-packs.md.
        let langPath = language.sdkLanguage.rawValue
        let required = [
            "v2.1/\(langPath)/cond_prefill_ane.mlmodelc/",
            "v2.1/\(langPath)/flowlm_step_ane.mlmodelc/",
            "v2.1/\(langPath)/flow_decoder_fused.mlmodelc/",
            "v2.1/\(langPath)/mimi_decoder.mlmodelc/",
            "v2.1/\(langPath)/constants_bin/",
        ]
        return await HuggingFaceTreeSizeFetcher.fetchTotalBytes(
            url: "https://huggingface.co/api/models/FluidInference/pocket-tts-coreml/tree/main/v2.1/\(langPath)?recursive=true",
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
