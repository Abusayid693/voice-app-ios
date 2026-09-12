import LucideSwift
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
                .tabItem { Label(title: { Text("Home") }, icon: { LucideIcon(.house) }) }
                .tag(RootTab.home)

            PlaceholderTabView(title: "Explore")
                .tabItem { Label(title: { Text("Explore") }, icon: { LucideIcon(.compass) }) }
                .tag(RootTab.explore)

            ImportHomeView(
                viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                libraryViewModel: libraryViewModel
            )
            .tabItem { Label(title: { Text("Import") }, icon: { LucideIcon(.circlePlus) }) }
            .tag(RootTab.importScreen)

            LibraryTabView(viewModel: libraryViewModel, ttsViewModel: viewModel)
                .tabItem { Label(title: { Text("Library") }, icon: { LucideIcon(.library) }) }
                .tag(RootTab.library)

            VoicesTabView(viewModel: voiceCloneViewModel)
                .tabItem { Label(title: { Text("Voices") }, icon: { LucideIcon(.audioWaveform) }) }
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
