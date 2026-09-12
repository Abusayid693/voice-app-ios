import SwiftUI

enum ChunkState {
    case waiting
    case generated
    case playing
    case failed

    /// Shared segmented-bar color, used by both `KokoroGenerationListView`
    /// (Home tab) and `ReadAlongPlayerView`'s player bar so the two chunk
    /// progress bars stay visually consistent.
    var displayColor: Color {
        switch self {
        case .playing: return .blue
        case .generated: return Color.blue.opacity(0.3)
        case .waiting: return Color.gray.opacity(0.25)
        case .failed: return .red
        }
    }
}
