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
    // Changing voice mid-session invalidates whichever model was preloaded
    // — a new voice genuinely needs its own pack preloaded.
    @Published var kokoroVoice = "af_heart" {
        didSet {
            guard oldValue != kokoroVoice else { return }
            kokoroModelsReady = false
        }
    }
    // Which Kokoro variant to use — one `KokoroAneManager` per variant (the
    // SDK's chain/vocab differ per variant, same reasoning as
    // `pocketLanguage`).
    @Published var kokoroVariant: KokoroVariant = .english {
        didSet {
            guard oldValue != kokoroVariant else { return }
            kokoroModelsReady = false
        }
    }
    @Published var pocketVoice = "alba"
    // Which Pocket TTS language pack to use — one `PocketTtsManager` per
    // language (the SDK fixes `language` at init).
    @Published var pocketLanguage: PocketLanguage = .english
    // Set by VoiceSettingsSheet's "My Voices" section — when non-nil (and
    // engine == .pocketTts), a cloned voice's conditioning data is used
    // instead of the named `pocketVoice` preset. Picking any normal voice
    // clears this back to nil.
    @Published var selectedClonedVoice: ClonedVoice?
    @Published var text = "Hello from FluidAudio!"
    @Published var status = "Idle"
    @Published var isBusy = false

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
    /// warming it for someone who's switched to Pocket would load the wrong
    /// one and pay the cost twice.
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

}
