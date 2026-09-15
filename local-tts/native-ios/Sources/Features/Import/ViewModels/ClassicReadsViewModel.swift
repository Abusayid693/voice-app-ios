import Foundation

/// Backs Import's "Classic reads" row. The 5 items are fixed and bundled
/// locally (no API, so no async loading state) — this exists as a real
/// ViewModel rather than static view-local data for structural consistency
/// with the rest of `Features/Import/`, and to own `playRandomPreview()`
/// without the section view touching `RandomClipPreviewService` directly.
@MainActor
final class ClassicReadsViewModel: ObservableObject {
    @Published private(set) var items: [ClassicReadItem] = [
        ClassicReadItem(
            id: "pride-and-prejudice", title: "Pride and Prejudice", authorName: "Jane Austen",
            coverAssetName: "BookCoverPrideAndPrejudice"),
        ClassicReadItem(
            id: "sense-and-sensibility", title: "Sense and Sensibility", authorName: "Jane Austen",
            coverAssetName: "BookCoverSenseAndSensibility"),
        ClassicReadItem(
            id: "the-odyssey", title: "The Odyssey", authorName: "Homer",
            coverAssetName: "BookCoverTheOdyssey"),
        ClassicReadItem(
            id: "moby-dick", title: "Moby-Dick", authorName: "Herman Melville",
            coverAssetName: "BookCoverMobyDick"),
        ClassicReadItem(
            id: "frankenstein", title: "Frankenstein", authorName: "Mary Shelley",
            coverAssetName: "BookCoverFrankenstein"),
    ]

    private let previewService = RandomClipPreviewService()

    /// There's no real book audio to preview yet — plays a random bundled
    /// voice-preview clip instead, as an honest-for-now placeholder.
    func playRandomPreview() {
        previewService.play()
    }
}
