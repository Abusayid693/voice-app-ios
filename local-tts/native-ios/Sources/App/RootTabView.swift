import LucideSwift
import SwiftUI
import UIKit

enum RootTab: Hashable {
    case home, explore, importScreen, library, voices
}

/// Rasterizes a Lucide icon to a template `Image`, for use as a `.tabItem`
/// icon only.
///
/// `LucideIcon` renders as a `ZStack` of stroked/filled vector `Shape`s, not
/// a plain `Image`. `.tabItem` builds each `UITabBarItem` through UIKit's own
/// image-extraction pipeline, which reliably rasterizes `Image` content but
/// not arbitrary custom SwiftUI views — on device this silently produced
/// blank tab bar icons, even though the exact same `LucideIcon` renders fine
/// as a toolbar button or inline icon elsewhere (those never go through this
/// extraction). Pre-rendering to a real `UIImage` and marking it
/// `.alwaysTemplate` sidesteps it: UIKit tints the bitmap itself
/// (selected/unselected color) exactly like an SF Symbol, instead of trying
/// to snapshot the live shape.
@MainActor
private func tabIcon(_ name: LucideIconName, size: CGFloat = 24) -> Image {
    let renderer = ImageRenderer(content: LucideIcon(name, size: size, color: .black))
    renderer.scale = UIScreen.main.scale
    guard let uiImage = renderer.uiImage?.withRenderingMode(.alwaysTemplate) else {
        return Image(systemName: "circle")
    }
    return Image(uiImage: uiImage)
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
                .tabItem { Label(title: { Text("Home") }, icon: { tabIcon(.house) }) }
                .tag(RootTab.home)

            PlaceholderTabView(title: "Explore")
                .tabItem { Label(title: { Text("Explore") }, icon: { tabIcon(.compass) }) }
                .tag(RootTab.explore)

            ImportHomeView(
                viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                libraryViewModel: libraryViewModel
            )
            .tabItem { Label(title: { Text("Import") }, icon: { tabIcon(.circlePlus) }) }
            .tag(RootTab.importScreen)

            LibraryTabView(viewModel: libraryViewModel, ttsViewModel: viewModel)
                .tabItem { Label(title: { Text("Library") }, icon: { tabIcon(.library) }) }
                .tag(RootTab.library)

            VoicesTabView(viewModel: voiceCloneViewModel)
                .tabItem { Label(title: { Text("Voices") }, icon: { tabIcon(.audioWaveform) }) }
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
