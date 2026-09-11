import SwiftUI

@main
struct KokoroAneTestApp: App {
    private let dependencies = DependencyContainer()
    private let viewModel: TTSViewModel
    private let voiceCloneViewModel: VoiceCloneViewModel

    init() {
        viewModel = TTSViewModel(dependencies: dependencies)
        voiceCloneViewModel = VoiceCloneViewModel(dependencies: dependencies)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel)
        }
    }
}
