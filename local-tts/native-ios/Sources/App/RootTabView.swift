import SwiftUI

enum RootTab: Hashable {
    case home, explore, importScreen, library, voices
}

/// App shell: the 5-tab bar from the redesign. Import is the default
/// screen; Home keeps the original engine/voice debug screen (unchanged);
/// Explore/Library/Voices are placeholders until they get real screens.
struct RootTabView: View {
    @ObservedObject var viewModel: TTSViewModel
    @State private var selectedTab: RootTab = .importScreen

    var body: some View {
        TabView(selection: $selectedTab) {
            TTSHomeView(viewModel: viewModel)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(RootTab.home)

            PlaceholderTabView(title: "Explore")
                .tabItem { Label("Explore", systemImage: "safari") }
                .tag(RootTab.explore)

            ImportHomeView(viewModel: viewModel)
                .tabItem { Label("Import", systemImage: "plus.circle.fill") }
                .tag(RootTab.importScreen)

            PlaceholderTabView(title: "Library")
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(RootTab.library)

            PlaceholderTabView(title: "Voices")
                .tabItem { Label("Voices", systemImage: "waveform") }
                .tag(RootTab.voices)
        }
    }
}

#Preview {
    RootTabView(viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
