import SwiftUI

@main
struct KokoroAneTestApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let dependencies = DependencyContainer()
    private let viewModel: TTSViewModel
    private let voiceCloneViewModel: VoiceCloneViewModel
    private let libraryViewModel: LibraryViewModel
    private let pdfImportManager: PDFImportManager
    private let previewPlayer = VoicePreviewPlayer()
    // Page reader audio dependencies:
    // ChapterSynthesisService needs viewModel.kokoroServices, so these are
    // built after viewModel rather than as bare property initializers.
    private let chapterSynthesisService: ChapterSynthesisService
    private let chapterGenerationStore: ChapterGenerationStore
    private let chapterPlayer: ChapterAudioPlayer
    private let navigationChrome = NavigationChromeVisibility()

    init() {
        libraryViewModel = LibraryViewModel()
        pdfImportManager = PDFImportManager(library: libraryViewModel)
        PDFImportManager.registerBackgroundTask(manager: pdfImportManager)
        viewModel = TTSViewModel(dependencies: dependencies)
        voiceCloneViewModel = VoiceCloneViewModel(dependencies: dependencies)
        chapterSynthesisService = ChapterSynthesisService(kokoroServices: viewModel.kokoroServices)
        chapterGenerationStore = ChapterGenerationStore(synthesisService: chapterSynthesisService)
        chapterPlayer = ChapterAudioPlayer(synthesisService: chapterSynthesisService)
    }

    private var appEnvironment: AppEnvironment {
        AppEnvironment(
            tts: viewModel, voiceClone: voiceCloneViewModel, library: libraryViewModel,
            pdfImports: pdfImportManager, previewPlayer: previewPlayer, chapterPlayer: chapterPlayer,
            generationStore: chapterGenerationStore, navigationChrome: navigationChrome)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(app: appEnvironment)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        pdfImportManager.applicationDidEnterBackground()
                    }
                }
        }
    }
}
