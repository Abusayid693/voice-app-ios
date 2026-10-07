import Combine
import FluidAudio
import Foundation

@MainActor
final class TTSViewModel: ObservableObject {
    private static let defaultVoicePreferenceKey = "tts.defaultKokoroVoice"
    private static let fallbackVoice = "af_heart"

    // Voice rosters live in `VoiceCatalog` alongside each voice's
    // avatar/tagline/description/preview line — these stay as plain code
    // lists for the call sites that only need names (pickers, counts, the
    // eager per-voice download loop).
    nonisolated static var kokoroVoices: [String] { kokoroVoices(for: .english) }
    nonisolated static var mandarinVoices: [String] { kokoroVoices(for: .mandarin) }

    nonisolated static func kokoroVoices(for variant: KokoroVariant) -> [String] {
        VoiceCatalog.voices(for: variant).map(\.code)
    }

    // Kokoro-ANE is the only engine — kept as a stored property rather than
    // dropped because it's what saved projects persist and what the reader
    // resolves a voice against.
    @Published var engine: Engine = .kokoroAne
    @Published var kokoroVoice: String
    // Which Kokoro variant to use — one `KokoroAneManager` per variant (the
    // SDK's chain/vocab differ per variant).
    @Published var kokoroVariant: KokoroVariant
    @Published var status = "Idle"
    @Published var isBusy = false

    // MARK: - Import screen: voice-pack setup

    /// Which packs are on disk, where, and any download in flight. Views that
    /// show pack state observe this directly (`viewModel.packs`) — nested
    /// ObservableObject changes don't reach a parent's objectWillChange.
    let packs: VoicePackStore

    // One service per variant, each wrapping that variant's own manager.
    // Exposed so ChapterSynthesisService can share the same instances.
    let kokoroServices: [KokoroVariant: KokoroEngineService]

    init(dependencies: DependencyContainer) {
        let storedVoice = UserDefaults.standard.string(forKey: Self.defaultVoicePreferenceKey)
        let resolvedVoice = storedVoice.flatMap { voice in
            VoiceCatalog.variant(forCode: voice) == nil ? nil : voice
        } ?? Self.fallbackVoice
        kokoroVoice = resolvedVoice
        kokoroVariant = VoiceCatalog.variant(forCode: resolvedVoice) ?? .english

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
        packs = VoicePackStore(
            kokoroModelDirectory: dependencies.kokoroModelDirectory,
            isKokoroPackBundled: dependencies.isKokoroPackBundled)
    }

    /// Settings owns the app-wide default. Reader voice changes still update
    /// their project without silently replacing this persisted preference.
    func setDefaultKokoroVoice(_ voice: String) {
        guard let variant = VoiceCatalog.variant(forCode: voice) else { return }
        kokoroVariant = variant
        kokoroVoice = voice
        UserDefaults.standard.set(voice, forKey: Self.defaultVoicePreferenceKey)
    }

    // MARK: - Import screen: Setup sheet actions

    /// For English, only meaningfully does anything if the bundled-copy
    /// step in DependencyContainer failed (isKokoroPackReady(.english)
    /// already false) — the common case is already ready before this could
    /// ever be called. For Mandarin/Japanese this is the real, and only,
    /// download path — no bundled fallback exists.
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
}
