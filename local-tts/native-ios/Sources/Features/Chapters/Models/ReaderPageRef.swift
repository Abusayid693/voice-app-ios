import Foundation

/// Stable identity shared by page generation, playback, and audio storage.
struct ReaderPageRef: Hashable {
    let projectID: UUID
    let pageIndex: Int
}
