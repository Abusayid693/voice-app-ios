import SwiftUI

@main
struct KokoroAneTestApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let dependencies = DependencyContainer()
    private let viewModel: TTSViewModel
    private let libraryViewModel: LibraryViewModel
    private let pdfImportManager: PDFImportManager
    private let previewPlayer = VoicePreviewPlayer()
    // Page reader audio dependencies:
    // ChapterSynthesisService needs viewModel.kokoroServices, so these are
    // built after viewModel rather than as bare property initializers.
    private let chapterSynthesisService: ChapterSynthesisService
    private let chapterPlayer: ChapterAudioPlayer
    // Music-style continuous playback (Features/Listening/) — a second,
    // independent playback owner sharing chapterSynthesisService's one FIFO
    // queue (not a second ChapterSynthesisService — see
    // docs/adr/0012-two-playback-engines.md for why two players but one
    // synthesis queue).
    private let bookPlayer: BookAudioPlayer
    private let navigationChrome = NavigationChromeVisibility()
    // Owned by ChapterAudioPlayer (Kokoro), the only engine that reaches
    // the reader.
    private let readingStatsTracker: ReadingStatsTracker
    // bookPlayer's own tracker, separate from readingStatsTracker: each
    // ReadingStatsTracker holds a single sessionID and self-closes it on a
    // new beginListening — sharing one between two independent playback
    // owners would let either silently end the other's session.
    private let bookStatsTracker: ReadingStatsTracker

    init() {
        libraryViewModel = LibraryViewModel()
        pdfImportManager = PDFImportManager(library: libraryViewModel)
        PDFImportManager.registerBackgroundTask(manager: pdfImportManager)
        readingStatsTracker = ReadingStatsTracker(store: dependencies.readingStatsStore)
        bookStatsTracker = ReadingStatsTracker(store: dependencies.readingStatsStore)
        viewModel = TTSViewModel(dependencies: dependencies)
        chapterSynthesisService = ChapterSynthesisService(kokoroServices: viewModel.kokoroServices)
        chapterPlayer = ChapterAudioPlayer(
            synthesisService: chapterSynthesisService, statsTracker: readingStatsTracker)
        bookPlayer = BookAudioPlayer(
            synthesis: chapterSynthesisService, statsTracker: bookStatsTracker)
        // Mutual exclusion: never let both engines sound at once. Pausing,
        // not stopping, so the yielded side's position and stats session
        // both survive — resuming it later is instant.
        chapterPlayer.willStartPlaying = { [bookPlayer] in bookPlayer.pauseIfPlaying() }
        bookPlayer.willStartPlaying = { [chapterPlayer] in chapterPlayer.pauseIfPlaying() }
        // Off-main, fire-and-forget — closes out any session left open by a
        // crash/force-quit last run. See ReadingStatsStore's own doc comment
        // on why this and container creation stay off the launch path.
        let statsStore = dependencies.readingStatsStore
        Task { await statsStore.closeStaleSessionsAtLaunch() }
    }

    private var appEnvironment: AppEnvironment {
        AppEnvironment(
            tts: viewModel, library: libraryViewModel,
            pdfImports: pdfImportManager, previewPlayer: previewPlayer, chapterPlayer: chapterPlayer,
            bookPlayer: bookPlayer,
            readingStats: dependencies.readingStatsStore,
            navigationChrome: navigationChrome)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(app: appEnvironment)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        pdfImportManager.applicationDidEnterBackground()
                        // Audio keeps playing once backgrounded and iOS can
                        // kill a suspended app without warning — flush what's
                        // accrued so far rather than relying solely on the
                        // ~20s checkpoint backstop. Both trackers: only one
                        // engine is ever actually sounding, but the paused
                        // one's tracker has nothing to flush and no-ops.
                        readingStatsTracker.flushForBackgrounding()
                        bookStatsTracker.flushForBackgrounding()
                    }
                }
        }
    }
}
