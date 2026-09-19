import SwiftUI

@main
struct KokoroAneTestApp: App {
    private let dependencies = DependencyContainer()
    private let viewModel: TTSViewModel
    private let voiceCloneViewModel: VoiceCloneViewModel
    private let libraryViewModel = LibraryViewModel()
    private let previewPlayer = VoicePreviewPlayer()
    // Chapters flow (issue: split Generate into save-then-chapters):
    // ChapterSynthesisService needs viewModel.kokoroServices, so these are
    // built after viewModel rather than as bare property initializers.
    private let chapterSynthesisService: ChapterSynthesisService
    private let chapterGenerationStore: ChapterGenerationStore
    private let chapterPlayer: ChapterAudioPlayer

    init() {
        viewModel = TTSViewModel(dependencies: dependencies)
        voiceCloneViewModel = VoiceCloneViewModel(dependencies: dependencies)
        chapterSynthesisService = ChapterSynthesisService(kokoroServices: viewModel.kokoroServices)
        chapterGenerationStore = ChapterGenerationStore(synthesisService: chapterSynthesisService)
        chapterPlayer = ChapterAudioPlayer(synthesisService: chapterSynthesisService)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                libraryViewModel: libraryViewModel, previewPlayer: previewPlayer,
                chapterPlayer: chapterPlayer, generationStore: chapterGenerationStore)
        }
    }
}
