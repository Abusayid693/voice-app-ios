import SwiftUI

@main
struct KokoroAneTestApp: App {
    private let dependencies = DependencyContainer()

    var body: some Scene {
        WindowGroup {
            TTSHomeView(viewModel: TTSViewModel(dependencies: dependencies))
        }
    }
}
