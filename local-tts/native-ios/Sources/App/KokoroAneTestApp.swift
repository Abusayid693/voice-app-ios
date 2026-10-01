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
    // The app's one playback owner — read-along and the audio surface are
    // two views of it (docs/adr/0013-unified-player.md).
    private let player: BookAudioPlayer
    private let readingStatsTracker: ReadingStatsTracker

    init() {
        libraryViewModel = LibraryViewModel()
        pdfImportManager = PDFImportManager(library: libraryViewModel)
        PDFImportManager.registerBackgroundTask(manager: pdfImportManager)
        readingStatsTracker = ReadingStatsTracker(store: dependencies.readingStatsStore)
        viewModel = TTSViewModel(dependencies: dependencies)
        chapterSynthesisService = ChapterSynthesisService(kokoroServices: viewModel.kokoroServices)
        player = BookAudioPlayer(
            synthesis: chapterSynthesisService, statsTracker: readingStatsTracker)
        // Off-main, fire-and-forget — closes out any session left open by a
        // crash/force-quit last run. See ReadingStatsStore's own doc comment
        // on why this and container creation stay off the launch path.
        let statsStore = dependencies.readingStatsStore
        Task { await statsStore.closeStaleSessionsAtLaunch() }
    }

    private var appEnvironment: AppEnvironment {
        AppEnvironment(
            tts: viewModel, library: libraryViewModel,
            pdfImports: pdfImportManager, previewPlayer: previewPlayer, player: player,
            readingStats: dependencies.readingStatsStore)
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
                        // ~20s checkpoint backstop.
                        readingStatsTracker.flushForBackgrounding()
                    }
                }
        }
    }
}
