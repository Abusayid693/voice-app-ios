import Hugeicons
import SwiftUI

/// A destination the Explore menu pushes onto Home's own navigation stack.
/// Home is the app's single root, not one of these — they were four peer
/// tabs before, each with its own stack; now Books *is* the app and the
/// rest are routes off it.
enum ExploreDestination: Hashable, CaseIterable, Identifiable {
    case library, voices, tools

    var id: Self { self }

    var title: String {
        switch self {
        case .library: return "Library"
        case .voices: return "Voices"
        case .tools: return "Tools"
        }
    }

    var icon: HugeiconsAsset {
        switch self {
        case .library: return Hugeicons.folderLibrary
        case .voices: return Hugeicons.audioWave02
        case .tools: return Hugeicons.bolt
        }
    }
}

/// Thin app shell; Home owns its navigation and shelf chrome.
struct RootTabView: View {
    let app: AppEnvironment

    var body: some View {
        ImportHomeView(libraryViewModel: app.library, app: app)
    }
}

#Preview {
    RootTabView(app: .preview())
}
