import Foundation

/// Where the reader left off, to chunk granularity — what `SavedGeneration`
/// persists and `BookAudioPlayer`'s `positionWriter` reports.
///
/// `chunkCount` rides along for two reasons. It guards against staleness:
/// `KokoroTextChunker.chunk` is a pure function of the page's text, so a
/// stored index normally stays valid forever, but a change to
/// `maxChunkLength` would silently point it somewhere else in the page — a
/// count mismatch is what lets the restore path notice and fall back to the
/// page's start. It's also the *denominator* progress needs: Library renders
/// from `SavedGenerationSummary`, which has no page text to re-chunk.
struct ReadingPosition: Equatable {
    let pageIndex: Int
    let chunkIndex: Int
    let chunkCount: Int

    /// A page with no chunks at all (a blank PDF page) still records which
    /// page it was.
    init(pageIndex: Int, chunkIndex: Int = 0, chunkCount: Int = 0) {
        self.pageIndex = pageIndex
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
    }
}
