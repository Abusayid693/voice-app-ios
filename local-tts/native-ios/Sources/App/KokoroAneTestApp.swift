import SwiftUI

@main
struct KokoroAneTestApp: App {
    private let dependencies = DependencyContainer()
    private let viewModel: TTSViewModel

    init() {
        viewModel = TTSViewModel(dependencies: dependencies)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(viewModel: viewModel)
        }
    }
}
