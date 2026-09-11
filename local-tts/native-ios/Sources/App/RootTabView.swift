import SwiftUI

enum RootTab: Hashable {
    case home, explore, importScreen, library, voices
}

/// App shell: the 5-tab bar from the redesign. Import is the default
/// screen; Home keeps the original engine/voice debug screen (unchanged);
/// Explore/Library are still placeholders; Voices manages cloned voices.
struct RootTabView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @State private var selectedTab: RootTab = .importScreen

    var body: some View {
        TabView(selection: $selectedTab) {
            TTSHomeView(viewModel: viewModel)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(RootTab.home)

            PlaceholderTabView(title: "Explore")
                .tabItem { Label("Explore", systemImage: "safari") }
                .tag(RootTab.explore)

            ImportHomeView(
                viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                libraryViewModel: libraryViewModel
            )
            .tabItem { Label("Import", systemImage: "plus.circle.fill") }
            .tag(RootTab.importScreen)

            LibraryTabView(viewModel: libraryViewModel)
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(RootTab.library)

            VoicesTabView(viewModel: voiceCloneViewModel)
                .tabItem { Label("Voices", systemImage: "waveform") }
                .tag(RootTab.voices)
        }
    }
}

#Preview {
    let dependencies = DependencyContainer()
    RootTabView(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel())
}
