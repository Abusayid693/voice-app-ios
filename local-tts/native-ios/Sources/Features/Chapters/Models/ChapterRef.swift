import Foundation

/// Identifies one chapter of one saved project — the key shared by
/// `ChapterGenerationStore` (progress), `ChapterAudioPlayer` (what's
/// playing), and `ChapterAudioStore` (where its files live).
struct ChapterRef: Hashable {
    let projectID: UUID
    let chapterIndex: Int
}
